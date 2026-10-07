import XCTest
@testable import DeviceHubProKit

final class SkinTests: XCTestCase {
    // MARK: - Layout parsing

    /// Modern single-portrait skin (`pixel_9_pro`).
    func testModernPhoneLayout() {
        let file = SkinLayout.parse(Self.pixel9ProLayout)

        XCTAssertNil(file.landscape)
        let portrait = try? XCTUnwrap(file.preferred)
        XCTAssertEqual(portrait?.orientation, .portrait)
        XCTAssertEqual(portrait?.displaySize, CGSize(width: 1280, height: 2856))
        XCTAssertEqual(portrait?.origin, CGPoint(x: 60, y: 61))
        XCTAssertEqual(portrait?.layoutSize, CGSize(width: 1408, height: 2974))
        XCTAssertEqual(portrait?.backgroundImage, "back.webp")
        XCTAssertEqual(portrait?.maskImage, "mask.webp")
        XCTAssertEqual(portrait?.cornerRadius, 109)
        XCTAssertEqual(
            portrait?.screenRect,
            CGRect(x: 60, y: 61, width: 1280, height: 2856)
        )
    }

    /// Foldables ship two layouts: open (`default`, landscape) and cover (`closed`).
    func testFoldableVariantLayouts() {
        let open = SkinLayout.parse(Self.pixelFoldDefaultLayout).preferred
        XCTAssertEqual(open?.orientation, .landscape)
        XCTAssertEqual(open?.displaySize, CGSize(width: 2208, height: 1840))
        XCTAssertEqual(open?.origin, CGPoint(x: 77, y: 126))
        XCTAssertNil(open?.cornerRadius)

        let cover = SkinLayout.parse(Self.pixelFoldClosedLayout).preferred
        XCTAssertEqual(cover?.orientation, .portrait)
        XCTAssertEqual(cover?.displaySize, CGSize(width: 1080, height: 2092))
        XCTAssertEqual(cover?.origin, CGPoint(x: 116, y: 73))
        XCTAssertEqual(cover?.maskImage, "mask.webp")
    }

    /// Landscape-only skins (tablets) resolve through the landscape section,
    /// even when the artwork part is literally named `portrait`.
    func testLandscapeOnlyTabletLayout() {
        let file = SkinLayout.parse(Self.pixelTabletLayout)

        XCTAssertNil(file.portrait)
        let landscape = try? XCTUnwrap(file.preferred)
        XCTAssertEqual(landscape?.orientation, .landscape)
        XCTAssertEqual(landscape?.displaySize, CGSize(width: 2560, height: 1600))
        XCTAssertEqual(landscape?.origin, CGPoint(x: 119, y: 117))
        XCTAssertEqual(landscape?.backgroundImage, "back.webp")
    }

    func testRoundWearLayout() {
        let display = SkinLayout.parse(Self.wearSmallRoundLayout).preferred
        XCTAssertEqual(display?.displaySize, CGSize(width: 384, height: 384))
        XCTAssertEqual(display?.origin, CGPoint(x: 36, y: 36))
        XCTAssertEqual(display?.layoutSize, CGSize(width: 456, height: 456))
        XCTAssertEqual(display?.backgroundImage, "device_bezel.png")
        XCTAssertEqual(display?.maskImage, "device_mask.png")
    }

    /// Legacy skins use an `onion` overlay (`port_fore.webp`) instead of a
    /// mask. Dropping it leaves the screen's square corners sticking out of
    /// the rounded frame.
    func testLegacyOnionOverlay() {
        let file = SkinLayout.parse(Self.nexus5Layout)

        let portrait = try? XCTUnwrap(file.portrait)
        XCTAssertEqual(portrait?.orientation, .portrait)
        XCTAssertEqual(portrait?.displaySize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(portrait?.origin, CGPoint(x: 144, y: 195))
        XCTAssertEqual(portrait?.backgroundImage, "port_back.webp")
        XCTAssertNil(portrait?.maskImage)
        XCTAssertEqual(portrait?.overlayImage, "port_fore.webp")

        let landscape = try? XCTUnwrap(file.landscape)
        XCTAssertEqual(landscape?.orientation, .landscape)
        XCTAssertEqual(landscape?.backgroundImage, "land_back.webp")
        XCTAssertEqual(landscape?.overlayImage, "land_fore.webp")
    }

    /// Some legacy skins carry both a corner mask and an onion overlay.
    func testLegacyMaskAndOnion() {
        let portrait = SkinLayout.parse(Self.pixel2XLLayout).portrait
        XCTAssertEqual(portrait?.maskImage, "round_corners.webp")
        XCTAssertEqual(portrait?.overlayImage, "port_fore.webp")
        XCTAssertEqual(portrait?.displaySize, CGSize(width: 1440, height: 2880))
    }

    func testNormalizedScreenRect() {
        let display = try? XCTUnwrap(SkinLayout.parse(Self.pixel9ProLayout).preferred)
        let rect = display?.normalizedScreenRect ?? .zero
        // origin 60,61 display 1280x2856 in a 1408x2974 layout.
        XCTAssertEqual(rect.minX, 60 / 1408, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 61 / 2974, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 1280 / 1408, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 2856 / 2974, accuracy: 0.0001)
    }

    /// Artwork a few pixels off its layout's size (the SDK's
    /// `pixel_10_pro_fold/closed`: 1236x2495 in a 1236x2554 layout) is drawn
    /// at its natural size from the artwork part's origin, not stretched;
    /// artwork exported at another scale is still mapped uniformly.
    func testArtworkKeepsItsNaturalSize() {
        let display = SkinDisplay(
            displaySize: CGSize(width: 1080, height: 2364),
            origin: CGPoint(x: 84, y: 66),
            layoutSize: CGSize(width: 1236, height: 2554),
            backgroundImage: "back.webp",
            maskImage: "mask.webp",
            orientation: .portrait
        )
        let natural = CGSize(width: 1236, height: 2495)
        XCTAssertEqual(display.artworkScale(pixelSize: natural), 1)
        XCTAssertEqual(display.artworkRect(pixelSize: natural), CGRect(x: 0, y: 0, width: 1236, height: 2495))

        // pixel_10_pro: 1410x2968 over 1408x2965 overhangs the layout box.
        let overhanging = CGSize(width: 1410, height: 2968)
        XCTAssertEqual(display.artworkScale(pixelSize: overhanging), 1)

        // A 2x re-export and a half-size one map at their width ratio.
        XCTAssertEqual(display.artworkScale(pixelSize: CGSize(width: 2472, height: 5108)), 2)
        XCTAssertEqual(
            display.artworkRect(pixelSize: CGSize(width: 2472, height: 5108)),
            CGRect(x: 0, y: 0, width: 1236, height: 2554)
        )
        XCTAssertEqual(display.artworkScale(pixelSize: CGSize(width: 618, height: 1277)), 0.5)
    }

    func testHeroLayoutFit() {
        let display = try? XCTUnwrap(SkinLayout.parse(Self.pixel9ProLayout).preferred)
        guard let display else { return }

        // Width-constrained: 1408x2974 into 500x1200 → scale 500/1408.
        let fit = SkinHeroLayout.fit(display: display, available: CGSize(width: 500, height: 1200))
        XCTAssertEqual(fit.scale, 500 / 1408, accuracy: 0.0001)
        XCTAssertEqual(fit.frame.width, 500, accuracy: 0.01)
        XCTAssertEqual(fit.frame.height, 2974 * 500 / 1408, accuracy: 0.01)
        XCTAssertEqual(fit.screen.minX, 60 * 500 / 1408, accuracy: 0.01)
        XCTAssertEqual(fit.screen.minY, 61 * 500 / 1408, accuracy: 0.01)
        XCTAssertEqual(fit.screen.width, 1280 * 500 / 1408, accuracy: 0.01)
        // The display's corner radius scales into hero points so the live
        // video can be clipped to it.
        XCTAssertEqual(fit.screenCornerRadius, 109 * 500 / 1408, accuracy: 0.01)

        // Never upscales past native pixels.
        let huge = SkinHeroLayout.fit(
            display: display,
            available: CGSize(width: 5000, height: 9000)
        )
        XCTAssertEqual(huge.scale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(huge.frame.size, CGSize(width: 1408, height: 2974))
        XCTAssertEqual(huge.screenCornerRadius, 109, accuracy: 0.01)
    }

    func testHeroLayoutRotation() {
        let display = try? XCTUnwrap(SkinLayout.parse(Self.pixel9ProLayout).preferred)
        guard let display else { return }
        // Base: frame 1408x2974, screen (60,61,1280,2856).
        let box = CGSize(width: 5000, height: 9000)

        func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.01, file: file, line: line)
        }

        let ccw = SkinHeroLayout.fit(display: display, available: box, rotation: 1)
        XCTAssertEqual(ccw.angle, -90)
        XCTAssertEqual(ccw.frame.size, CGSize(width: 2974, height: 1408))
        // (x, y, w, h) -> (y, W - x - w, h, w) with W = 1408.
        assertRect(ccw.screen, CGRect(x: 61, y: 1408 - 60 - 1280, width: 2856, height: 1280))

        let cw = SkinHeroLayout.fit(display: display, available: box, rotation: 3)
        XCTAssertEqual(cw.angle, -270)
        XCTAssertEqual(cw.frame.size, CGSize(width: 2974, height: 1408))
        // (x, y, w, h) -> (H - y - h, x, h, w) with H = 2974.
        assertRect(cw.screen, CGRect(x: 2974 - 61 - 2856, y: 60, width: 2856, height: 1280))

        let upsideDown = SkinHeroLayout.fit(display: display, available: box, rotation: 2)
        XCTAssertEqual(upsideDown.angle, -180)
        XCTAssertEqual(upsideDown.frame.size, CGSize(width: 1408, height: 2974))
        assertRect(
            upsideDown.screen,
            CGRect(x: 1408 - 60 - 1280, y: 2974 - 61 - 2856, width: 1280, height: 2856)
        )

        // The posed screen stays inside the posed frame in every rotation.
        for rotation in 0..<4 {
            let hero = SkinHeroLayout.fit(display: display, available: box, rotation: rotation)
            XCTAssertTrue(
                hero.frame.insetBy(dx: -1, dy: -1).contains(hero.screen),
                "rotation \(rotation): \(hero.screen) not in \(hero.frame)"
            )
        }

        // A rotated frame is scaled to fit transposed: portrait box, landscape pose.
        let tight = SkinHeroLayout.fit(
            display: display,
            available: CGSize(width: 500, height: 900),
            rotation: 1
        )
        XCTAssertEqual(tight.frame.width, 500, accuracy: 0.01)
        XCTAssertLessThanOrEqual(tight.frame.height, 900)
        XCTAssertEqual(tight.scale, 500 / 2974, accuracy: 0.0001)
    }

    /// The live stage's layout: the unrotated skin at the fit of the pose it
    /// rests in (`PoseFit`). At the landscape pose's fit it is the portrait
    /// skin at the scale the transposed `fit(rotation: 1)` picks, so the
    /// wrapper turns it into landscape without enlarging it.
    func testNativeHeroLayoutAtThePosesFit() throws {
        let display = try XCTUnwrap(SkinLayout.parse(Self.pixel9ProLayout).preferred)
        let box = CGSize(width: 1284, height: 810)

        let portrait = SkinHeroLayout.native(
            display: display,
            scale: PoseFit.scale(angle: 0, nativeSize: display.layoutSize, box: box)
        )
        XCTAssertEqual(portrait, SkinHeroLayout.fit(display: display, available: box))

        let landscapeScale = PoseFit.scale(angle: -90, nativeSize: display.layoutSize, box: box)
        let posed = SkinHeroLayout.fit(display: display, available: box, rotation: 1)
        XCTAssertEqual(landscapeScale, posed.scale)
        let landscape = SkinHeroLayout.native(display: display, scale: landscapeScale)
        XCTAssertEqual(landscape.angle, 0, "the wrapper turns it, not the layout")
        XCTAssertEqual(landscape.frame.size, CGSize(width: posed.frame.height, height: posed.frame.width))
        XCTAssertEqual(landscape.screen.size, CGSize(width: posed.screen.height, height: posed.screen.width))
        XCTAssertEqual(landscape.screen.minX, 60 * landscapeScale, accuracy: 1e-9)
        XCTAssertEqual(landscape.screenCornerRadius, 109 * landscapeScale, accuracy: 1e-9)
        // 1284 / 2974 against 810 / 2974: the landscape layout is 1.59x the
        // portrait one here, which the wrapper used to make up by enlarging.
        XCTAssertEqual(landscape.scale / portrait.scale, 1284.0 / 810, accuracy: 1e-9)
    }

    func testVariantMatching() {
        let fold = ResolvedSkin(
            name: "pixel_fold",
            directory: URL(fileURLWithPath: "/skins/pixel_fold"),
            source: .deviceName,
            variants: [
                SkinVariant(
                    id: "default",
                    directory: URL(fileURLWithPath: "/skins/pixel_fold/default"),
                    layout: SkinLayout.parse(Self.pixelFoldDefaultLayout)
                ),
                SkinVariant(
                    id: "closed",
                    directory: URL(fileURLWithPath: "/skins/pixel_fold/closed"),
                    layout: SkinLayout.parse(Self.pixelFoldClosedLayout)
                ),
            ]
        )

        // Open frame (2208x1840, landscape) → default; cover (1080x2092) → closed.
        XCTAssertEqual(
            fold.variant(matching: CGSize(width: 2208, height: 1840))?.id,
            "default"
        )
        XCTAssertEqual(
            fold.variant(matching: CGSize(width: 1080, height: 2092))?.id,
            "closed"
        )
        // A rotated open fold still matches the open variant, not the cover.
        XCTAssertEqual(
            fold.variant(matching: CGSize(width: 1840, height: 2208))?.id,
            "default"
        )

        let phone = ResolvedSkin(
            name: "pixel_9_pro",
            directory: URL(fileURLWithPath: "/skins/pixel_9_pro"),
            source: .deviceName,
            variants: [
                SkinVariant(
                    id: "default",
                    directory: URL(fileURLWithPath: "/skins/pixel_9_pro"),
                    layout: SkinLayout.parse(Self.pixel9ProLayout)
                )
            ]
        )
        XCTAssertEqual(
            phone.variant(matching: CGSize(width: 1080, height: 2400))?.id,
            "default"
        )
    }

    func testBrokenLayoutYieldsNoDisplay() {
        XCTAssertNil(SkinLayout.parse("not a layout\n} { \n").preferred)
        XCTAssertNil(SkinLayout.parse("").preferred)
    }

    // MARK: - AVD resolution

    func testResolverPrefersSkinPath() throws {
        let root = try temporaryRoot()
        let skins = root.appendingPathComponent("skins", isDirectory: true)
        let custom = skins.appendingPathComponent("custom_phone", isDirectory: true)
        try writeLayout(Self.pixel9ProLayout, to: custom)
        try writeLayout(Self.pixel9ProLayout, to: skins.appendingPathComponent("pixel_8a"))

        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        try writeConfig(
            """
            hw.device.name=pixel_8a
            skin.path=\(custom.path)
            """,
            avdName: "Test",
            avdHome: avdHome
        )

        let resolved = try XCTUnwrap(
            SkinResolver.resolve(avdName: "Test", skinsDirectory: skins, avdHome: avdHome)
        )
        XCTAssertEqual(resolved.name, "custom_phone")
        XCTAssertEqual(resolved.source, .skinPath)
        XCTAssertFalse(resolved.isFoldable)
        XCTAssertNotNil(resolved.preferredVariant?.layout?.preferred)
    }

    /// A generic `skin.name` with no directory (like the real `Pixel_Fold`
    /// AVD's `2208x1840`) falls back to `hw.device.name`.
    func testResolverFallsBackToDeviceName() throws {
        let root = try temporaryRoot()
        let skins = root.appendingPathComponent("skins", isDirectory: true)
        try writeLayout(Self.pixel9ProLayout, to: skins.appendingPathComponent("pixel_4"))

        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        try writeConfig(
            """
            hw.device.name=pixel_4
            skin.name=2208x1840
            """,
            avdName: "Fold",
            avdHome: avdHome
        )

        let resolved = try XCTUnwrap(
            SkinResolver.resolve(avdName: "Fold", skinsDirectory: skins, avdHome: avdHome)
        )
        XCTAssertEqual(resolved.name, "pixel_4")
        XCTAssertEqual(resolved.source, .deviceName)
    }

    /// AVDs without any `skin.*` keys resolve through `hw.device.name`.
    func testResolverWithoutSkinKeys() throws {
        let root = try temporaryRoot()
        let skins = root.appendingPathComponent("skins", isDirectory: true)
        try writeLayout(Self.pixel9ProLayout, to: skins.appendingPathComponent("pixel_8a"))

        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        try writeConfig("hw.device.name=pixel_8a\n", avdName: "Plain", avdHome: avdHome)

        let resolved = try XCTUnwrap(
            SkinResolver.resolve(avdName: "Plain", skinsDirectory: skins, avdHome: avdHome)
        )
        XCTAssertEqual(resolved.source, .deviceName)
    }

    func testResolverReturnsNilWithoutMatch() throws {
        let root = try temporaryRoot()
        let skins = root.appendingPathComponent("skins", isDirectory: true)
        try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)

        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        try writeConfig("hw.device.name=unknown_device\n", avdName: "Ghost", avdHome: avdHome)

        XCTAssertNil(SkinResolver.resolve(avdName: "Ghost", skinsDirectory: skins, avdHome: avdHome))
        XCTAssertNil(SkinResolver.resolve(avdName: "Missing", skinsDirectory: skins, avdHome: avdHome))
    }

    func testFoldableVariants() throws {
        let root = try temporaryRoot()
        let skins = root.appendingPathComponent("skins", isDirectory: true)
        let fold = skins.appendingPathComponent("pixel_fold", isDirectory: true)
        try writeLayout(
            Self.pixelFoldDefaultLayout,
            to: fold.appendingPathComponent("default", isDirectory: true)
        )
        try writeLayout(
            Self.pixelFoldClosedLayout,
            to: fold.appendingPathComponent("closed", isDirectory: true)
        )

        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        try writeConfig("hw.device.name=pixel_fold\n", avdName: "Fold", avdHome: avdHome)

        let resolved = try XCTUnwrap(
            SkinResolver.resolve(avdName: "Fold", skinsDirectory: skins, avdHome: avdHome)
        )
        XCTAssertTrue(resolved.isFoldable)
        XCTAssertEqual(resolved.variants.map(\.id), ["default", "closed"])
        XCTAssertEqual(
            resolved.preferredVariant?.layout?.preferred?.orientation,
            .landscape
        )
    }

    // MARK: - Catalog

    func testCatalogCategories() throws {
        let root = try temporaryRoot()
        let skins = root.appendingPathComponent("skins", isDirectory: true)
        for name in ["pixel_9", "pixel_fold", "pixel_tablet", "tv_1080p", "wearos_small_round"] {
            try writeLayout(Self.pixel9ProLayout, to: skins.appendingPathComponent(name))
        }
        // Not a skin: no layout file.
        try FileManager.default.createDirectory(
            at: skins.appendingPathComponent("NOTICE"),
            withIntermediateDirectories: true
        )

        let catalog = SkinResolver.catalog(skinsDirectory: skins)
        let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0) })
        XCTAssertEqual(byName.count, 5)
        XCTAssertEqual(byName["pixel_9"]?.category, .phone)
        XCTAssertEqual(byName["pixel_fold"]?.category, .foldable)
        XCTAssertEqual(byName["pixel_tablet"]?.category, .tablet)
        XCTAssertEqual(byName["tv_1080p"]?.category, .tv)
        XCTAssertEqual(byName["wearos_small_round"]?.category, .wear)
    }

    func testDisplayNames() {
        XCTAssertEqual(SkinResolver.displayName(forSkinName: "pixel_9_pro"), "Pixel 9 Pro")
        XCTAssertEqual(SkinResolver.displayName(forSkinName: "pixel_fold"), "Pixel Fold")
        XCTAssertEqual(SkinResolver.displayName(forSkinName: "nexus_7_2013"), "Nexus 7 2013")
        XCTAssertEqual(SkinResolver.displayName(forSkinName: "galaxy_nexus"), "Galaxy Nexus")
        XCTAssertEqual(SkinResolver.displayName(forSkinName: "tv_1080p"), "TV 1080p")
    }

    // MARK: - AvdConfig

    func testAvdDisplayNameAndTarget() throws {
        let root = try temporaryRoot()
        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        try writeConfig(
            """
            AvdId=Pixel_9_Pro_Fold
            avd.ini.displayname=Pixel 9 Pro Fold
            hw.lcd.width=2076
            hw.lcd.height=2152
            """,
            avdName: "Pixel_9_Pro_Fold",
            avdHome: avdHome
        )
        try "target=android-37.1\n".write(
            to: avdHome.appendingPathComponent("Pixel_9_Pro_Fold.ini"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            AvdConfig.displayName(avdName: "Pixel_9_Pro_Fold", avdHome: avdHome),
            "Pixel 9 Pro Fold"
        )
        XCTAssertEqual(
            AvdConfig.target(avdName: "Pixel_9_Pro_Fold", avdHome: avdHome),
            "android-37.1"
        )
        XCTAssertEqual(
            AvdConfig.lcdSize(avdName: "Pixel_9_Pro_Fold", avdHome: avdHome),
            CGSize(width: 2076, height: 2152)
        )
        XCTAssertEqual(AvdConfig.displayName(avdName: "Missing", avdHome: avdHome), "Missing")
        XCTAssertNil(AvdConfig.target(avdName: "Missing", avdHome: avdHome))
    }

    /// `setSkin` adds the three skin keys without disturbing the rest, and
    /// replaces existing ones on a second call.
    func testSetSkinWritesAndReplacesKeys() throws {
        let root = try temporaryRoot()
        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        try writeConfig(
            """
            hw.device.name=pixel_10_pro
            hw.lcd.width=1280
            skin.name=old_name
            skin.path=/tmp/old
            """,
            avdName: "Pixel_10_Pro",
            avdHome: avdHome
        )

        try AvdConfig.setSkin(
            avdName: "Pixel_10_Pro",
            skinName: "pixel_10_pro",
            skinPath: "/sdk/skins/pixel_10_pro",
            avdHome: avdHome
        )
        var values = AvdConfig.values(avdName: "Pixel_10_Pro", avdHome: avdHome)
        XCTAssertEqual(values["skin.name"], "pixel_10_pro")
        XCTAssertEqual(values["skin.path"], "/sdk/skins/pixel_10_pro")
        XCTAssertEqual(values["skin.dynamic"], "yes")
        XCTAssertEqual(values["hw.device.name"], "pixel_10_pro")
        XCTAssertEqual(values["hw.lcd.width"], "1280")

        try AvdConfig.setSkin(
            avdName: "Pixel_10_Pro",
            skinName: "pixel_10_pro_xl",
            skinPath: "/sdk/skins/pixel_10_pro_xl",
            avdHome: avdHome
        )
        values = AvdConfig.values(avdName: "Pixel_10_Pro", avdHome: avdHome)
        XCTAssertEqual(values["skin.name"], "pixel_10_pro_xl")
        XCTAssertEqual(values["skin.path"], "/sdk/skins/pixel_10_pro_xl")
        let text = try String(
            contentsOf: AvdConfig.configURL(avdName: "Pixel_10_Pro", avdHome: avdHome),
            encoding: .utf8
        )
        XCTAssertEqual(text.components(separatedBy: "skin.name=").count - 1, 1)
    }

    /// A CRLF config used to come back from the `"\n"` split as one line, so
    /// the old `skin.*` keys survived next to the new ones.
    func testSetSkinReplacesKeysInACRLFConfig() throws {
        let root = try temporaryRoot()
        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        try writeConfig(
            "avd.ini.encoding=UTF-8\r\nskin.name=old_name\r\nskin.path=/tmp/old\r\nhw.lcd.width=1280\r\n",
            avdName: "Pixel_10_Pro",
            avdHome: avdHome
        )

        try AvdConfig.setSkin(
            avdName: "Pixel_10_Pro",
            skinName: "pixel_10_pro",
            skinPath: "/sdk/skins/pixel_10_pro",
            avdHome: avdHome
        )

        XCTAssertEqual(
            try String(
                contentsOf: AvdConfig.configURL(avdName: "Pixel_10_Pro", avdHome: avdHome),
                encoding: .utf8
            ),
            "avd.ini.encoding=UTF-8\r\nhw.lcd.width=1280\r\n"
                + "skin.name=pixel_10_pro\r\nskin.path=/sdk/skins/pixel_10_pro\r\nskin.dynamic=yes\r\n"
        )
    }

    // MARK: - Real SDK

    /// Guards the parser and the catalog against the real SDK skins when they
    /// are installed; skipped on machines without the SDK.
    func testRealSdkSkins() throws {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }

        let catalog = SkinResolver.catalog(skinsDirectory: skins)
        XCTAssertGreaterThanOrEqual(catalog.count, 40, "expected the full SDK skin set")

        let names = Set(catalog.map(\.name))
        XCTAssertTrue(names.contains("pixel_9_pro"))
        XCTAssertTrue(names.contains("pixel_fold"))

        if let fold = catalog.first(where: { $0.name == "pixel_fold" }) {
            XCTAssertEqual(fold.category, .foldable)
            XCTAssertEqual(Set(fold.variants.map(\.id)), ["default", "closed"])
        }

        let pro = try XCTUnwrap(catalog.first(where: { $0.name == "pixel_9_pro" }))
        let display = try XCTUnwrap(pro.preferredVariant?.layout?.preferred)
        XCTAssertEqual(display.displaySize, CGSize(width: 1280, height: 2856))
        XCTAssertEqual(display.cornerRadius, 109)

        // Real corner-radius numbers across the SDK's rounded-display skins.
        if let ten = catalog.first(where: { $0.name == "pixel_10" }) {
            let tenDisplay = try XCTUnwrap(ten.preferredVariant?.layout?.preferred)
            XCTAssertEqual(tenDisplay.cornerRadius, 87)
            // pixel_10's artwork (1205x2535) misses its layout (1198x2531) by a
            // few pixels; it is drawn at its natural size, as the emulator
            // does, so neither the display rect nor the radius is stretched.
            let skin = ResolvedSkin(
                name: ten.name,
                directory: ten.directory,
                source: .skinName,
                variants: ten.variants
            )
            let spec = try XCTUnwrap(DeviceFrameRenderer.spec(for: skin))
            XCTAssertEqual(spec.cornerRadius ?? 0, 87, accuracy: 0.01)
            XCTAssertEqual(spec.displayRect, CGRect(x: 59, y: 55, width: 1080, height: 2424))
        }

        if let fold = catalog.first(where: { $0.name == "pixel_10_pro_fold" }),
           let closed = fold.variants.first(where: { $0.id == "closed" })
        {
            XCTAssertEqual(closed.layout?.preferred?.cornerRadius, 75)
        }

        if let wear = catalog.first(where: { $0.name == "wearos_xl_round" }) {
            let wearDisplay = try XCTUnwrap(wear.preferredVariant?.layout?.preferred)
            XCTAssertEqual(wearDisplay.cornerRadius, 210)
            let skin = ResolvedSkin(
                name: wear.name,
                directory: wear.directory,
                source: .skinName,
                variants: wear.variants
            )
            let spec = try XCTUnwrap(DeviceFrameRenderer.spec(for: skin))
            XCTAssertEqual(spec.cornerRadius ?? 0, 210, accuracy: 0.01)
        }
    }

    // MARK: - Helpers

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkinTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeLayout(_ text: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(
            to: directory.appendingPathComponent("layout"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeConfig(_ text: String, avdName: String, avdHome: URL) throws {
        let directory = avdHome.appendingPathComponent("\(avdName).avd", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(
            to: directory.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static let pixel9ProLayout = """
        parts {
          device {
            display {
              width 1280
              height 2856
              x 0
              y 0
              corner_radius 109
            }
          }
          portrait {
            background {
              image back.webp
            }
            foreground {
              mask mask.webp
              cutout hole
            }
          }
        }
        layouts {
          portrait {
            width 1408
            height 2974
            event EV_SW:0:1
            part1 {
              name portrait
              x 0
              y 0
            }
            part2 {
              name device
              x 60
              y 61
            }
          }
        }
        """

    private static let pixelFoldDefaultLayout = """
        parts {
          device {
            display {
              width 2208
              height 1840
              x 0
              y 0
            }
          }
          portrait {
            background {
              image back.webp
            }
            foreground {
              mask mask.webp
            }
          }
        }
        layouts {
          landscape {
            width 2368
            height 2087
            event EV_SW:0:1
            part1 {
              name portrait
              x 0
              y 0
            }
            part2 {
              name device
              x 77
              y 126
            }
          }
        }
        """

    private static let pixelFoldClosedLayout = """
        parts {
          device {
            display {
              width 1080
              height 2092
              x 0
              y 0
            }
          }
          portrait {
            background {
              image back.webp
            }
            foreground {
              mask mask.webp
              cutout hole
            }
          }
        }
        layouts {
          portrait {
            width 1268
            height 2233
            event EV_SW:0:1
            part1 {
              name portrait
              x 0
              y 0
            }
            part2 {
              name device
              x 116
              y 73
            }
          }
        }
        """

    private static let pixelTabletLayout = """
        parts {
          device {
            display {
              width 2560
              height 1600
              x 0
              y 0
            }
          }
          portrait {
            background {
              image back.webp
            }
            foreground {
              mask mask.webp
            }
          }
        }
        layouts {
          landscape {
            width 2798
            height 1837
            event EV_SW:0:1
            part1 {
              name portrait
              x 0
              y 0
            }
            part2 {
              name device
              x 119
              y 117
            }
          }
        }
        """

    private static let nexus5Layout = """
        parts {
          device {
            display {
              width 1080
              height 1920
              x 0
              y 0
            }
          }
          portrait {
            background {
              image port_back.webp
            }
            onion {
              image port_fore.webp
            }
          }
          landscape {
            background {
              image land_back.webp
            }
            onion {
              image land_fore.webp
            }
          }
        }
        layouts {
          portrait {
            width 1370
            height 2405
            event EV_SW:0:1
            part1 {
              name portrait
              x 0
              y 0
            }
            part2 {
              name device
              x 144
              y 195
            }
          }
          landscape {
            width 2497
            height 1235
            event EV_SW:0:0
            part1 {
              name landscape
              x 0
              y 0
            }
            part2 {
              name device
              x 261
              y 1145
              rotation 3
            }
          }
        }
        """

    private static let pixel2XLLayout = """
        parts {
          device {
            display {
              width 1440
              height 2880
              x 0
              y 0
            }
          }
          portrait {
            background {
              image port_back.webp
            }
            foreground {
              mask    round_corners.webp
              padding 20
            }
            onion {
              image port_fore.webp
            }
          }
          landscape {
            background {
              image land_back.webp
            }
            onion {
              image land_fore.webp
            }
          }
        }
        layouts {
          portrait {
            width 1858
            height 3456
            event EV_SW:0:1
            part1 {
              name portrait
              x 0
              y 0
            }
            part2 {
              name device
              x 201
              y 245
            }
          }
        }
        """

    private static let wearSmallRoundLayout = """
        parts {
            portrait {
                background {
                    image   device_bezel.png
                }
                foreground {
                    mask    device_mask.png
                }
            }

            device {
                display {
                    width   384
                    height  384
                    x       0
                    y       0
                }
            }
        }

        layouts {
            portrait {
                width     456
                height    456

                part1 {
                    name    portrait
                    x       0
                    y       0
                }

                part2 {
                    name    device
                    x       36
                    y       36
                }
            }
        }
        """
}
