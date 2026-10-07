import XCTest
@testable import DeviceHubProKit

/// The skin `layout` parser, the skin catalog/resolver, `AvdConfig`,
/// `AvdDisplayRepair` and `AvdFileOperations` against real files: layouts
/// copied from the SDK's `skins/` and `config.ini`/`<name>.ini` files copied
/// from `~/.android/avd/` (see `LogcatSdkApkFixtures`). Tests that write
/// always work on copies in a temporary AVD home whose pointer files, if
/// any, point into that home — never at the real AVD a captured `path=`
/// names.
final class SkinAvdRealFilesTests: XCTestCase {
    private var skins: URL { LogcatSdkApkFixtures.url("skins") }
    private var avdHome: URL { LogcatSdkApkFixtures.url("avd") }

    private func layout(_ path: String) throws -> SkinLayoutFile {
        try XCTUnwrap(SkinLayout.parseFile(at: skins.appendingPathComponent(path)))
    }

    // MARK: - Layout files

    func testModernPhoneLayout() throws {
        let file = try layout("pixel_9_pro/layout")
        XCTAssertNil(file.landscape)
        XCTAssertEqual(file.portrait, SkinDisplay(
            displaySize: CGSize(width: 1280, height: 2856),
            origin: CGPoint(x: 60, y: 61),
            layoutSize: CGSize(width: 1408, height: 2974),
            backgroundImage: "back.webp",
            maskImage: "mask.webp",
            overlayImage: nil,
            orientation: .portrait,
            cornerRadius: 109,
            declaresCutout: true
        ))
    }

    /// The open fold names its only layout section `landscape` although the
    /// art part is `portrait`.
    func testFoldOpenAndCoverLayouts() throws {
        let open = try layout("pixel_9_pro_fold/default/layout")
        XCTAssertNil(open.portrait)
        XCTAssertEqual(open.preferred, SkinDisplay(
            displaySize: CGSize(width: 2076, height: 2152),
            origin: CGPoint(x: 62, y: 62),
            layoutSize: CGSize(width: 2204, height: 2274),
            backgroundImage: "back.webp",
            maskImage: "mask.webp",
            orientation: .landscape
        ))

        let cover = try layout("pixel_9_pro_fold/closed/layout")
        XCTAssertNil(cover.landscape)
        XCTAssertEqual(cover.portrait, SkinDisplay(
            displaySize: CGSize(width: 1080, height: 2424),
            origin: CGPoint(x: 94, y: 70),
            layoutSize: CGSize(width: 1236, height: 2554),
            backgroundImage: "back.webp",
            maskImage: "mask.webp",
            orientation: .portrait,
            cornerRadius: 75,
            declaresCutout: true
        ))
    }

    /// A legacy skin: both orientations, `onion` overlays and a `buttons`
    /// block nested one level deeper than the artwork keys. The landscape
    /// device part carries `rotation 3`, which the parser does not model:
    /// its display stays portrait-shaped (a known limitation
    /// `DeviceFrameRenderer` works around).
    func testLegacyLayoutWithButtonsAndBothOrientations() throws {
        let file = try layout("nexus_one/layout")
        XCTAssertEqual(file.portrait, SkinDisplay(
            displaySize: CGSize(width: 480, height: 800),
            origin: CGPoint(x: 125, y: 131),
            layoutSize: CGSize(width: 732, height: 1178),
            backgroundImage: "port_back.webp",
            maskImage: nil,
            overlayImage: "port_fore.webp",
            orientation: .portrait
        ))
        XCTAssertEqual(file.landscape, SkinDisplay(
            displaySize: CGSize(width: 480, height: 800),
            origin: CGPoint(x: 200, y: 532),
            layoutSize: CGSize(width: 1300, height: 612),
            backgroundImage: "land_back.webp",
            maskImage: nil,
            overlayImage: "land_fore.webp",
            orientation: .landscape
        ))
    }

    /// `mask    round_corners.webp` (a run of spaces) next to `padding 20`.
    func testMaskAfterARunOfSpaces() throws {
        let portrait = try XCTUnwrap(try layout("pixel_2_xl/layout").portrait)
        XCTAssertEqual(portrait.maskImage, "round_corners.webp")
        XCTAssertEqual(portrait.overlayImage, "port_fore.webp")
        XCTAssertEqual(portrait.displaySize, CGSize(width: 1440, height: 2880))
        XCTAssertEqual(portrait.origin, CGPoint(x: 201, y: 245))
        XCTAssertEqual(portrait.layoutSize, CGSize(width: 1858, height: 3456))
    }

    /// `pixel_tablet/layout` is the one SDK layout without a final newline.
    func testLayoutWithoutATrailingNewline() throws {
        let bytes = try Data(contentsOf: skins.appendingPathComponent("pixel_tablet/layout"))
        XCTAssertEqual(bytes.last, UInt8(ascii: "}"))
        let landscape = try XCTUnwrap(try layout("pixel_tablet/layout").landscape)
        XCTAssertEqual(landscape.displaySize, CGSize(width: 2560, height: 1600))
        XCTAssertEqual(landscape.origin, CGPoint(x: 119, y: 117))
        XCTAssertEqual(landscape.layoutSize, CGSize(width: 2798, height: 1837))
    }

    /// The automotive skins open with an Apache license header in `#`
    /// comments.
    func testLayoutWithALicenseHeader() throws {
        let text = try LogcatSdkApkFixtures.text("skins/automotive_ultrawide_cutout/layout")
        XCTAssertTrue(text.hasPrefix("# Copyright (C) 2024 The Android Open Source Project\n"))
        let file = try layout("automotive_ultrawide_cutout/layout")
        XCTAssertNil(file.portrait)
        XCTAssertEqual(file.landscape, SkinDisplay(
            displaySize: CGSize(width: 3904, height: 1320),
            origin: CGPoint(x: 50, y: 50),
            layoutSize: CGSize(width: 4004, height: 1420),
            backgroundImage: "back.png",
            maskImage: nil,
            orientation: .landscape
        ))
    }

    /// `wearos_rect` is one of two SDK skins that place their artwork part
    /// off the layout's origin (`part1 { name portrait x 16 y 16 }`). Its
    /// 434x508 artwork is 32 px smaller than the layout on both axes: only
    /// placed at (16, 16) at its natural size does its 16 px bezel frame the
    /// display at (32, 32).
    func testArtworkPartPlacementIsKept() throws {
        let display = try XCTUnwrap(try layout("wearos_rect/layout").portrait)
        XCTAssertEqual(display, SkinDisplay(
            displaySize: CGSize(width: 402, height: 476),
            origin: CGPoint(x: 32, y: 32),
            layoutSize: CGSize(width: 466, height: 540),
            backgroundImage: "device_bezel.png",
            maskImage: nil,
            orientation: .portrait,
            artworkOrigin: CGPoint(x: 16, y: 16)
        ))
        let artwork = display.artworkRect(pixelSize: CGSize(width: 434, height: 508))
        XCTAssertEqual(artwork, CGRect(x: 16, y: 16, width: 434, height: 508))
        let screen = display.screenRect
        XCTAssertEqual(
            [screen.minX - artwork.minX, screen.minY - artwork.minY, artwork.maxX - screen.maxX, artwork.maxY - screen.maxY],
            [16, 16, 16, 16]
        )
    }

    // MARK: - Catalog

    func testCatalogOfRealSkinDirectories() throws {
        let catalog = SkinResolver.catalog(skinsDirectory: skins)
        XCTAssertEqual(catalog.map(\.name), [
            "automotive_ultrawide_cutout",
            "nexus_one",
            "pixel_2_xl",
            "pixel_7a",
            "pixel_9_pro",
            "pixel_9_pro_fold",
            "pixel_9_pro_xl",
            "pixel_fold",
            "pixel_silver",
            "pixel_tablet",
            "wearos_rect",
            "wearos_xl_round",
        ])
        XCTAssertEqual(catalog.map(\.displayName), [
            "Automotive Ultrawide Cutout",
            "Nexus One",
            "Pixel 2 XL",
            "Pixel 7a",
            "Pixel 9 Pro",
            "Pixel 9 Pro Fold",
            "Pixel 9 Pro XL",
            "Pixel Fold",
            "Pixel Silver",
            "Pixel Tablet",
            "Wear OS Rect",
            "Wear OS XL Round",
        ])
        XCTAssertEqual(catalog.map(\.category), [
            .automotive, .phone, .phone, .phone, .phone, .foldable, .phone, .foldable, .phone, .tablet, .wear, .wear,
        ])
        let fold = try XCTUnwrap(catalog.first { $0.name == "pixel_9_pro_fold" })
        XCTAssertEqual(fold.variants.map(\.id), ["default", "closed"])
        XCTAssertEqual(fold.preferredVariant?.id, "default")
    }

    // MARK: - AVD config.ini

    /// Android Studio's `config.ini` of the running Pixel 9 Pro Fold AVD.
    func testFoldAvdConfig() {
        XCTAssertEqual(AvdConfig.hingeCount(avdName: "Pixel_9_Pro_Fold", avdHome: avdHome), 1)
        XCTAssertEqual(AvdConfig.displayName(avdName: "Pixel_9_Pro_Fold", avdHome: avdHome), "Pixel 9 Pro Fold")
        XCTAssertEqual(
            AvdConfig.lcdSize(avdName: "Pixel_9_Pro_Fold", avdHome: avdHome),
            CGSize(width: 2076, height: 2152)
        )
        let values = AvdConfig.values(avdName: "Pixel_9_Pro_Fold", avdHome: avdHome)
        XCTAssertEqual(values.count, 69)
        XCTAssertEqual(values["hw.sensor.posture_list"], "1, 2, 3")
        XCTAssertEqual(values["fastboot.chosenSnapshotFile"], "")
        XCTAssertEqual(values["image.sysdir.1"], "system-images/android-37.1/google_apis_playstore_ps16k/arm64-v8a/")
    }

    /// A `config.ini` without `AvdId`, `avd.ini.displayname` or any `skin.*`
    /// key (the Pixel 9 Pro AVD).
    func testAvdConfigWithoutNameKeys() {
        XCTAssertEqual(AvdConfig.displayName(avdName: "Pixel_9_Pro", avdHome: avdHome), "Pixel_9_Pro")
        XCTAssertEqual(AvdConfig.hingeCount(avdName: "Pixel_9_Pro", avdHome: avdHome), 0)
        XCTAssertEqual(
            AvdConfig.lcdSize(avdName: "Pixel_9_Pro", avdHome: avdHome),
            CGSize(width: 1280, height: 2856)
        )
        XCTAssertNil(AvdConfig.values(avdName: "Pixel_9_Pro", avdHome: avdHome)["skin.name"])
    }

    /// `hw.lcd.density` of each real config: the fold's 390, Pixel Fold's
    /// 379, Pixel 9 Pro's 480; nil for an AVD that is not there.
    func testLcdDensityOfRealConfigs() {
        XCTAssertEqual(AvdConfig.lcdDensity(avdName: "Pixel_9_Pro_Fold", avdHome: avdHome), 390)
        XCTAssertEqual(AvdConfig.lcdDensity(avdName: "Pixel_Fold", avdHome: avdHome), 379)
        XCTAssertEqual(AvdConfig.lcdDensity(avdName: "Pixel_9_Pro", avdHome: avdHome), 480)
        XCTAssertNil(AvdConfig.lcdDensity(avdName: "No_Such_AVD", avdHome: avdHome))
    }

    /// Only an AVD whose `hw.resizable.configs` lists sizes is resizable.
    /// The real configs list none; Pixel 9 Pro's
    /// `hw.sensor.hinge.resizable.config=1` (which the emulator writes on
    /// every AVD) does not count. No resizable AVD was on the capture host,
    /// so that config is written here in the `name-id-width-height-dpi`
    /// grammar the SDK's `hardware-properties.ini` gives for the key.
    func testResizableAvdConfig() throws {
        XCTAssertFalse(AvdConfig.isResizable(avdName: "Pixel_9_Pro_Fold", avdHome: avdHome))
        XCTAssertEqual(AvdConfig.values(avdName: "Pixel_9_Pro", avdHome: avdHome)["hw.sensor.hinge.resizable.config"], "1")
        XCTAssertFalse(AvdConfig.isResizable(avdName: "Pixel_9_Pro", avdHome: avdHome))
        XCTAssertFalse(AvdConfig.isResizable(avdName: "No_Such_AVD", avdHome: avdHome))

        let home = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "avd-resizable")
        func write(_ name: String, _ config: String) throws {
            let directory = home.appendingPathComponent("\(name).avd", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(config.utf8).write(to: directory.appendingPathComponent("config.ini"))
        }
        try write("Resizable_API_35", """
        hw.device.name=resizable\r
        hw.resizable.configs=phone-0-1080-2400-420, foldable-1-2208-1840-420, tablet-2-2560-1600-320, desktop-3-1920-1080-160\r

        """)
        try write("Blank_Configs", "hw.device.name=resizable\nhw.resizable.configs= \n")
        XCTAssertTrue(AvdConfig.isResizable(avdName: "Resizable_API_35", avdHome: home))
        XCTAssertFalse(AvdConfig.isResizable(avdName: "Blank_Configs", avdHome: home))
    }

    /// `<name>.ini` pointer files: `target=` is the image's API.
    func testTargetsFromRealPointerFiles() {
        let pointers = LogcatSdkApkFixtures.url("avd-pointers")
        XCTAssertEqual(AvdConfig.target(avdName: "Pixel_9_Pro_Fold", avdHome: pointers), "android-37.1")
        XCTAssertEqual(AvdConfig.target(avdName: "Pixel_10_Pro", avdHome: pointers), "android-36.1")
        XCTAssertEqual(AvdConfig.target(avdName: "Pixel_Fold", avdHome: pointers), "android-35")
    }

    /// A real pointer names the content directory twice: the absolute
    /// `path=` of the capture host, then `path.rel=avd/Pixel_Fold.avd`
    /// relative to the home's parent. Where the absolute directory exists
    /// (the capture host) it wins; anywhere else `path.rel` resolves to the
    /// fixture's own `avd/Pixel_Fold.avd`.
    func testContentDirectoryFromARealPointer() {
        let pointers = LogcatSdkApkFixtures.url("avd-pointers")
        let absolute = URL(fileURLWithPath: "/Users/testeruser/.android/avd/Pixel_Fold.avd", isDirectory: true)
        let expected = FileManager.default.fileExists(atPath: absolute.appendingPathComponent("config.ini").path)
            ? absolute
            : avdHome.appendingPathComponent("Pixel_Fold.avd", isDirectory: true)
        XCTAssertEqual(
            AvdConfig.contentDirectory(avdName: "Pixel_Fold", avdHome: pointers).standardizedFileURL,
            expected.standardizedFileURL
        )
    }

    /// The AVDs that stop booting when an image is removed, matched on the
    /// real `image.sysdir.1` values (trailing slash included). The pointer
    /// files are empty here: only their names list the AVDs.
    func testAvdNamesUsingARealSystemImage() throws {
        let home = try copiedHome(["Pixel_9_Pro_Fold", "Pixel_9_Pro", "Pixel_Fold"], emptyPointers: true)
        XCTAssertEqual(
            AvdConfig.avdNames(
                usingSystemImage: "system-images;android-37.1;google_apis_playstore_ps16k;arm64-v8a",
                avdHome: home
            ),
            ["Pixel_9_Pro", "Pixel_9_Pro_Fold"]
        )
        XCTAssertEqual(
            AvdConfig.avdNames(usingSystemImage: "system-images;android-35;google_apis;arm64-v8a", avdHome: home),
            ["Pixel_Fold"]
        )
    }

    // MARK: - Skin resolution

    /// `skin.path` (an absolute SDK path) first, then `skin.name`, then
    /// `hw.device.name`. Pixel_Fold's `skin.name=2208x1840` names no skin
    /// directory, and Pixel_9_Pro has no `skin.*` key at all.
    func testSkinResolutionOfRealConfigs() throws {
        let fold = try XCTUnwrap(SkinResolver.resolve(avdName: "Pixel_9_Pro_Fold", skinsDirectory: skins, avdHome: avdHome))
        XCTAssertEqual(fold.name, "pixel_9_pro_fold")
        // The captured `skin.path` exists only on the capture host.
        XCTAssertTrue([SkinSource.skinPath, .skinName].contains(fold.source))
        XCTAssertEqual(fold.variants.map(\.id), ["default", "closed"])
        XCTAssertEqual(fold.variant(matching: CGSize(width: 2076, height: 2152))?.id, "default")
        XCTAssertEqual(fold.variant(matching: CGSize(width: 1080, height: 2424))?.id, "closed")

        let pixelFold = try XCTUnwrap(SkinResolver.resolve(avdName: "Pixel_Fold", skinsDirectory: skins, avdHome: avdHome))
        XCTAssertEqual(pixelFold.name, "pixel_fold")
        XCTAssertEqual(pixelFold.source, .deviceName)

        let pixel9 = try XCTUnwrap(SkinResolver.resolve(avdName: "Pixel_9_Pro", skinsDirectory: skins, avdHome: avdHome))
        XCTAssertEqual(pixel9.name, "pixel_9_pro")
        XCTAssertEqual(pixel9.source, .deviceName)
    }

    func testPixelCatalogMatchesRealAvdsToTheirSkins() {
        let devices = PixelCatalog.devices(
            skins: SkinResolver.catalog(skinsDirectory: skins),
            installedAvdNames: ["Pixel_9_Pro_Fold", "Pixel_9_Pro", "Pixel_Fold"],
            avdDevices: [],
            avdHome: avdHome
        )
        func avds(_ skin: String) -> [String]? {
            devices.first { $0.skinName == skin }?.installedAvdNames
        }
        XCTAssertEqual(avds("pixel_9_pro_fold"), ["Pixel_9_Pro_Fold"])
        XCTAssertEqual(avds("pixel_9_pro"), ["Pixel_9_Pro"])
        XCTAssertEqual(avds("pixel_fold"), ["Pixel_Fold"])
        XCTAssertEqual(avds("pixel_silver"), [])
        XCTAssertNil(avds("nexus_one"), "only Pixel skins are Pixel devices")
    }

    // MARK: - Display repair

    /// The original Pixel Fold profile declares the cover's height
    /// (2208x2092) against the open skin's 2208x1840. Repairing the original
    /// `config.ini` must write exactly the file Device Hub Pro wrote on the capture
    /// host (`config.ini` next to the kept `config.ini.devicehubpro-bak`).
    func testRepairOfTheRealPixelFoldConfig() throws {
        let original = try LogcatSdkApkFixtures.data("avd/Pixel_Fold.avd/config.ini.devicehubpro-bak")
        let repairedOnHost = try LogcatSdkApkFixtures.data("avd/Pixel_Fold.avd/config.ini")
        let home = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "avd-repair-real")
        let config = home.appendingPathComponent("Pixel_Fold.avd/config.ini")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try original.write(to: config)

        let skin = SkinResolver.resolve(avdName: "Pixel_Fold", skinsDirectory: skins, avdHome: home)
        XCTAssertEqual(skin?.name, "pixel_fold")
        XCTAssertEqual(
            AvdDisplayRepair.diagnose(avdName: "Pixel_Fold", skin: skin, avdHome: home),
            AvdDisplayRepair.Mismatch(
                lcd: CGSize(width: 2208, height: 2092),
                skin: CGSize(width: 2208, height: 1840)
            )
        )
        XCTAssertEqual(
            AvdDisplayRepair.repair(avdName: "Pixel_Fold", skin: skin, avdHome: home),
            .repaired(from: CGSize(width: 2208, height: 2092), to: CGSize(width: 2208, height: 1840))
        )
        XCTAssertEqual(try Data(contentsOf: config), repairedOnHost)
        XCTAssertEqual(
            try Data(contentsOf: config.deletingLastPathComponent().appendingPathComponent(AvdDisplayRepair.backupFileName)),
            original
        )
        XCTAssertNil(AvdDisplayRepair.diagnose(avdName: "Pixel_Fold", skin: skin, avdHome: home))

        XCTAssertTrue(AvdDisplayRepair.restoreDisplaySize(avdName: "Pixel_Fold", avdHome: home))
        XCTAssertEqual(try Data(contentsOf: config), original)
    }

    /// Real configs whose LCD already matches the skin need no repair.
    func testRealConfigsThatAlreadyMatchTheirSkin() {
        for name in ["Pixel_9_Pro_Fold", "Pixel_9_Pro", "Pixel_Fold"] {
            let skin = SkinResolver.resolve(avdName: name, skinsDirectory: skins, avdHome: avdHome)
            XCTAssertNil(AvdDisplayRepair.diagnose(avdName: name, skin: skin, avdHome: avdHome), name)
        }
    }

    /// `setSkin` on the original Pixel Fold config: its lone mid-file
    /// `skin.name=2208x1840` is replaced by the three managed keys at the end;
    /// every other byte stays.
    func testSetSkinOnTheRealPixelFoldConfig() throws {
        let original = try LogcatSdkApkFixtures.text("avd/Pixel_Fold.avd/config.ini.devicehubpro-bak")
        let home = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "avd-skin-real")
        let config = home.appendingPathComponent("Pixel_Fold.avd/config.ini")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(original.utf8).write(to: config)

        try AvdConfig.setSkin(
            avdName: "Pixel_Fold",
            skinName: "pixel_fold",
            skinPath: "/sdk/skins/pixel_fold",
            avdHome: home
        )

        XCTAssertTrue(original.contains("\nskin.name=2208x1840\n"))
        XCTAssertEqual(
            try String(contentsOf: config, encoding: .utf8),
            original.replacingOccurrences(of: "skin.name=2208x1840\n", with: "")
                + "skin.name=pixel_fold\nskin.path=/sdk/skins/pixel_fold\nskin.dynamic=yes\n"
        )
    }

    // MARK: - Rename

    /// Renaming rewrites `AvdId` (it carries the old id) but keeps the custom
    /// `avd.ini.displayname=Pixel 9 Pro Fold`; every other byte of the real
    /// `config.ini` is unchanged. The pointer is the captured one with its
    /// `path=` moved into the temporary home.
    func testRenameOfARealAvd() throws {
        let home = try copiedHome(["Pixel_9_Pro_Fold"], emptyPointers: false)
        let original = try LogcatSdkApkFixtures.text("avd/Pixel_9_Pro_Fold.avd/config.ini")

        try AvdFileOperations.rename(avdName: "Pixel_9_Pro_Fold", to: "Fold_Renamed", avdHome: home)

        let config = try String(
            contentsOf: home.appendingPathComponent("Fold_Renamed.avd/config.ini"),
            encoding: .utf8
        )
        XCTAssertEqual(
            config,
            original.replacingOccurrences(of: "AvdId=Pixel_9_Pro_Fold\n", with: "AvdId=Fold_Renamed\n")
        )
        XCTAssertTrue(config.contains("\navd.ini.displayname=Pixel 9 Pro Fold\n"))
        let pointer = try String(contentsOf: home.appendingPathComponent("Fold_Renamed.ini"), encoding: .utf8)
        XCTAssertEqual(pointer, """
            avd.ini.encoding=UTF-8
            path=\(home.appendingPathComponent("Fold_Renamed.avd").path)
            path.rel=avd/Fold_Renamed.avd
            target=android-37.1

            """)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Pixel_9_Pro_Fold.avd").path))
    }

    // MARK: - Helpers

    /// A temporary AVD home with copies of the named fixture AVDs. Pointer
    /// files are empty, or the captured pointer with `path=` rewritten into
    /// the temporary home (so nothing can reach the capture host's AVDs).
    private func copiedHome(_ names: [String], emptyPointers: Bool) throws -> URL {
        let home = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "avd-home-real")
            .appendingPathComponent("avd", isDirectory: true)
        for name in names {
            let directory = home.appendingPathComponent("\(name).avd", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try LogcatSdkApkFixtures.data("avd/\(name).avd/config.ini")
                .write(to: directory.appendingPathComponent("config.ini"))
            var pointer = ""
            if !emptyPointers {
                pointer = try LogcatSdkApkFixtures.text("avd-pointers/\(name).ini")
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.hasPrefix("path=") ? "path=\(directory.path)" : String($0) }
                    .joined(separator: "\n")
                XCTAssertTrue(pointer.contains("path.rel=avd/\(name).avd\n"))
            }
            try Data(pointer.utf8).write(to: home.appendingPathComponent("\(name).ini"))
        }
        return home
    }
}
