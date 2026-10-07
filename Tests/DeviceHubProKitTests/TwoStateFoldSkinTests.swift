import XCTest
@testable import DeviceHubProKit

/// The Pixel 10 Pro Fold: a two-state skin (`default/` opened, `closed/`
/// cover, no top-level layout) and the AVD the app wrote for it.
///
/// Fixtures under `Fixtures/api35-emulator/pixel-10-pro-fold/`: the two
/// `layout` files are byte-exact copies of the SDK's
/// `skins/pixel_10_pro_fold/{default,closed}/layout`; `config-excerpt.ini` is
/// the matching lines of the AVD's `config.ini` (trimmed to the keys the tests
/// read; the home path replaced by the same-length `aqauser001`).
///
/// The frame sizes below were measured on an emulator 36.6.11 running that AVD
/// (API 35, gRPC `getScreenshot`, display 0). `hw.initialOrientation=portrait`
/// (what the app used to write for it): physical model rotation -90, guest
/// ROTATION_270, frame 2152x2076 rotation 3. `landscape` (what Android Studio
/// writes for a fold, and the app now does): physical rotation 0, ROTATION_0,
/// frame 2076x2152 rotation 0.
final class TwoStateFoldSkinTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api35-emulator/pixel-10-pro-fold", isDirectory: true)

    private func skin() throws -> ResolvedSkin {
        // A skins directory in the SDK's shape: only the two state folders.
        let variants = ["default", "closed"].map { id -> SkinVariant in
            let dir = Self.root.appendingPathComponent(id, isDirectory: true)
            return SkinVariant(
                id: id,
                directory: dir,
                layout: SkinLayout.parseFile(at: dir.appendingPathComponent("layout"))
            )
        }
        return ResolvedSkin(
            name: "pixel_10_pro_fold",
            directory: Self.root,
            source: .skinName,
            variants: variants
        )
    }

    func testBothStatesParse() throws {
        let skin = try skin()
        let open = try XCTUnwrap(skin.variants[0].layout?.preferred)
        XCTAssertEqual(open.displaySize, CGSize(width: 2076, height: 2152))
        XCTAssertEqual(open.origin, CGPoint(x: 62, y: 58))
        XCTAssertEqual(open.layoutSize, CGSize(width: 2204, height: 2274))
        let cover = try XCTUnwrap(skin.variants[1].layout?.preferred)
        XCTAssertEqual(cover.displaySize, CGSize(width: 1080, height: 2364))
        XCTAssertEqual(cover.origin, CGPoint(x: 84, y: 66))
        XCTAssertEqual(cover.layoutSize, CGSize(width: 1236, height: 2554))
        // `cutout hole` is declared by the cover's foreground only.
        XCTAssertFalse(open.declaresCutout)
        XCTAssertTrue(cover.declaresCutout)
        XCTAssertTrue(skin.isFoldable)
        XCTAssertEqual(skin.preferredVariant?.id, "default")
    }

    /// Every frame the AVD can stream picks the state that shows it: the
    /// opened screen in either pose (2152x2076 is the quarter-turned
    /// 2076x2152), the cover in either pose, never the other way round.
    func testVariantFollowsTheStreamedFrame() throws {
        let skin = try skin()
        for size in [CGSize(width: 2076, height: 2152), CGSize(width: 2152, height: 2076)] {
            XCTAssertEqual(skin.variant(matching: size)?.id, "default", "\(size)")
        }
        for size in [CGSize(width: 1080, height: 2364), CGSize(width: 2364, height: 1080)] {
            XCTAssertEqual(skin.variant(matching: size)?.id, "closed", "\(size)")
        }
    }

    func testConfigExcerptDescribesAFold() throws {
        let text = try String(
            contentsOf: Self.root.appendingPathComponent("config-excerpt.ini"),
            encoding: .utf8
        )
        func value(_ key: String) -> String? { EmulatorIni.value(of: key, in: text) }
        XCTAssertEqual(value("hw.lcd.width"), "2076")
        XCTAssertEqual(value("hw.lcd.height"), "2152")
        XCTAssertEqual(value("hw.displayRegion.0.1.width"), "1080")
        XCTAssertEqual(value("hw.displayRegion.0.1.height"), "2364")
        XCTAssertEqual(value("hw.sensor.hinge.count"), "1")
        XCTAssertEqual(value("skin.dynamic"), "yes")
        // A scrubbed capture: the home folder is the same-length placeholder.
        XCTAssertTrue(text.contains("/Users/aqauser001/"))
    }

    /// The root cause of the sideways stage: the LCD is taller than wide, so
    /// the size rule alone said `portrait` for a foldable.
    func testAFoldIsWrittenLandscapeWhateverItsLcd() {
        XCTAssertEqual(AvdConfig.initialOrientation(lcdWidth: 2076, lcdHeight: 2152), "portrait")
        for id in ["pixel_10_pro_fold", "pixel_9_pro_fold", "pixel_fold"] {
            XCTAssertEqual(
                AvdConfig.initialOrientation(deviceId: id, lcdWidth: 2076, lcdHeight: 2152),
                "landscape", id
            )
        }
        // Everything else keeps the size rule.
        XCTAssertEqual(AvdConfig.initialOrientation(deviceId: "pixel_10_pro", lcdWidth: 1280, lcdHeight: 2856), "portrait")
        XCTAssertEqual(AvdConfig.initialOrientation(deviceId: "tv_1080p", lcdWidth: 1920, lcdHeight: 1080), "landscape")
    }
}
