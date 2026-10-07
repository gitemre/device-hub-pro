import CoreGraphics
import ImageIO
import XCTest
@testable import DeviceHubProKit

/// The side-button scan and the button art against the installed SDK skins
/// (read in place, skipped without the SDK; Google's artwork is never copied
/// into the repo), plus the scan rule itself on alpha planes the tests draw
/// (generated input, not device output).
///
/// The expected rows are the installed SDK's (`skins/` of the Android SDK,
/// 2026-09-25): the Tier 2 research's prototype scan measured pixel_10_pro
/// at 830–1062 / 1199–1605 (baseline 1399, 10 px deep), pixel_8 at
/// 670–834 / 971–1302 and the open 9 Pro Fold at about 678–885 / 1035–1325;
/// the snapshot of the whole set was taken with this scanner and agrees
/// with them. A changed skin shows up as a failed snapshot.
final class SkinButtonsTests: XCTestCase {
    // MARK: - Installed skins

    private func skinsDirectory() throws -> URL {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        return skins
    }

    /// The frame artwork of `skin` (`name` or `name/variant`) as the stage
    /// draws it: the preferred display's background image.
    private func artworkURL(_ skin: String) throws -> URL {
        let parts = skin.split(separator: "/").map(String.init)
        let catalog = SkinResolver.catalog(skinsDirectory: try skinsDirectory())
        guard let entry = catalog.first(where: { $0.name == parts[0] }) else {
            throw XCTSkip("\(parts[0]) is not installed")
        }
        let variant = try XCTUnwrap(
            parts.count > 1 ? entry.variants.first { $0.id == parts[1] } : entry.preferredVariant,
            "\(skin) has no such variant"
        )
        let display = try XCTUnwrap(variant.layout?.preferred, "\(skin) has no layout")
        let image = try XCTUnwrap(display.backgroundImage, "\(skin) has no frame image")
        return variant.directory.appendingPathComponent(image)
    }

    /// Every installed variant with a frame image, keyed `name` for a
    /// single-variant skin and `name/variant` for a foldable.
    private func installedArtwork() throws -> [(skin: String, url: URL)] {
        SkinResolver.catalog(skinsDirectory: try skinsDirectory()).flatMap { entry in
            entry.variants.compactMap { variant -> (String, URL)? in
                guard let image = variant.layout?.preferred?.backgroundImage else { return nil }
                let skin = entry.variants.count > 1 ? "\(entry.name)/\(variant.id)" : entry.name
                return (skin, variant.directory.appendingPathComponent(image))
            }
        }
    }

    /// One accepted scan in short: rows are inclusive artwork rows.
    private struct Scan: Equatable, CustomStringConvertible {
        var baseline: Int
        var power: ClosedRange<Int>
        var powerDepth: Int
        var rocker: ClosedRange<Int>
        var rockerDepth: Int

        init(
            _ baseline: Int,
            power: ClosedRange<Int>,
            _ powerDepth: Int,
            rocker: ClosedRange<Int>,
            _ rockerDepth: Int
        ) {
            self.baseline = baseline
            self.power = power
            self.powerDepth = powerDepth
            self.rocker = rocker
            self.rockerDepth = rockerDepth
        }

        /// The scan's three buttons summed up; nil when they are not
        /// power, volume up and volume down split as the scanner splits.
        init?(_ buttons: [SkinHardwareButton]) {
            guard buttons.map(\.key) == [.power, .volumeUp, .volumeDown],
                  buttons.map(\.group) == [0, 1, 1],
                  Set(buttons.map(\.baseline)).count == 1,
                  buttons[1].depth == buttons[2].depth,
                  buttons[1].rect.maxY == buttons[2].rect.minY
            else {
                return nil
            }
            func rows(_ rect: CGRect) -> ClosedRange<Int> { Int(rect.minY)...(Int(rect.maxY) - 1) }
            baseline = buttons[0].baseline
            power = rows(buttons[0].rect)
            powerDepth = buttons[0].depth
            rocker = rows(buttons[1].rect.union(buttons[2].rect))
            rockerDepth = buttons[1].depth
        }

        var description: String {
            "Scan(\(baseline), power: \(power), \(powerDepth), rocker: \(rocker), \(rockerDepth))"
        }
    }

    /// Every installed skin variant the scan accepts, with its result.
    /// Anything installed and not listed must scan to no buttons: the
    /// tablets, Wear, TV, automotive, the older Nexus skins and the 9 Pro
    /// Fold's flat cover.
    private static let accepted: [String: Scan] = [
        "nexus_5x": Scan(1277, power: 628...789, 11, rocker: 954...1313, 7),
        "nexus_6": Scan(1733, power: 999...1156, 9, rocker: 1251...1609, 8),
        "nexus_6p": Scan(1693, power: 1054...1252, 10, rocker: 1375...1774, 9),
        "pixel_10": Scan(1196, power: 708...906, 8, rocker: 1023...1371, 8),
        "pixel_10_pro": Scan(1399, power: 830...1062, 10, rocker: 1199...1605, 10),
        "pixel_10_pro_fold/default": Scan(2195, power: 675...884, 5, rocker: 1032...1322, 5),
        "pixel_10_pro_fold/closed": Scan(1228, power: 742...974, 7, rocker: 1134...1456, 7),
        "pixel_10_pro_xl": Scan(1462, power: 842...1070, 9, rocker: 1205...1603, 9),
        "pixel_2": Scan(1269, power: 647...816, 12, rocker: 1023...1360, 9),
        "pixel_2_xl": Scan(1727, power: 801...1007, 10, rocker: 1261...1681, 10),
        "pixel_3": Scan(1184, power: 550...722, 9, rocker: 898...1244, 9),
        "pixel_3_xl": Scan(1633, power: 752...956, 11, rocker: 1163...1572, 11),
        "pixel_3a": Scan(1222, power: 665...836, 11, rocker: 1013...1358, 11),
        "pixel_3a_xl": Scan(1193, power: 586...803, 11, rocker: 930...1242, 11),
        "pixel_4": Scan(1168, power: 608...761, 6, rocker: 920...1228, 8),
        "pixel_4_xl": Scan(1558, power: 810...1016, 9, rocker: 1227...1638, 11),
        "pixel_4a": Scan(1195, power: 583...744, 8, rocker: 906...1228, 8),
        "pixel_5": Scan(1203, power: 594...763, 7, rocker: 934...1275, 5),
        "pixel_6": Scan(1202, power: 645...804, 6, rocker: 935...1255, 6),
        "pixel_6_pro": Scan(1519, power: 943...1140, 7, rocker: 1305...1704, 7),
        "pixel_6a": Scan(1201, power: 626...793, 5, rocker: 929...1264, 5),
        "pixel_7": Scan(1192, power: 750...912, 6, rocker: 1076...1400, 7),
        "pixel_7_pro": Scan(1535, power: 1070...1269, 11, rocker: 1471...1870, 11),
        "pixel_7a": Scan(1219, power: 715...882, 6, rocker: 1053...1387, 6),
        "pixel_8": Scan(1178, power: 670...834, 8, rocker: 971...1302, 8),
        "pixel_8_pro": Scan(1458, power: 986...1173, 10, rocker: 1330...1708, 10),
        "pixel_8a": Scan(1189, power: 750...909, 7, rocker: 1075...1398, 8),
        "pixel_9": Scan(1190, power: 689...885, 7, rocker: 1001...1363, 7),
        "pixel_9_pro": Scan(1399, power: 810...1040, 8, rocker: 1177...1602, 8),
        "pixel_9_pro_fold/default": Scan(2199, power: 678...885, 4, rocker: 1035...1325, 4),
        "pixel_9_pro_xl": Scan(1457, power: 822...1048, 8, rocker: 1181...1597, 8),
        "pixel_9a": Scan(1216, power: 709...906, 7, rocker: 1024...1388, 7),
        "pixel_fold/default": Scan(2360, power: 620...835, 7, rocker: 974...1270, 7),
        "pixel_fold/closed": Scan(1260, power: 661...891, 7, rocker: 1041...1358, 6),
        "pixel_silver": Scan(1287, power: 616...787, 7, rocker: 997...1341, 8),
        "pixel_xl_silver": Scan(1720, power: 779...984, 8, rocker: 1237...1653, 8),
    ]

    func testThePixel10ProButtons() throws {
        let buttons = SkinButtonScanner.scan(artworkURL: try artworkURL("pixel_10_pro"))
        XCTAssertEqual(buttons, [
            SkinHardwareButton(
                key: .power, group: 0,
                rect: CGRect(x: 1400, y: 830, width: 10, height: 233),
                baseline: 1399, depth: 10
            ),
            SkinHardwareButton(
                key: .volumeUp, group: 1,
                rect: CGRect(x: 1400, y: 1199, width: 10, height: 203),
                baseline: 1399, depth: 10
            ),
            SkinHardwareButton(
                key: .volumeDown, group: 1,
                rect: CGRect(x: 1400, y: 1402, width: 10, height: 204),
                baseline: 1399, depth: 10
            ),
        ], "power 830–1062 and the rocker 1199–1605 split at its midpoint, reaching x 1409")
    }

    func testThePixel8Buttons() throws {
        let scan = Scan(SkinButtonScanner.scan(artworkURL: try artworkURL("pixel_8")))
        XCTAssertEqual(scan?.power, 670...834)
        XCTAssertEqual(scan?.rocker, 971...1302)
    }

    /// The open 9 Pro Fold paints its buttons dark and only 4 px deep; the
    /// two prototype scans put their ends 2–3 rows apart, so the ramps are
    /// allowed ±3 rows.
    func testThePixel9ProFoldOpenButtons() throws {
        let scan = try XCTUnwrap(Scan(SkinButtonScanner.scan(artworkURL: try artworkURL("pixel_9_pro_fold/default"))))
        XCTAssertEqual(scan.power.lowerBound, 678, accuracy: 3)
        XCTAssertEqual(scan.power.upperBound, 885, accuracy: 3)
        XCTAssertEqual(scan.rocker.lowerBound, 1035, accuracy: 3)
        XCTAssertEqual(scan.rocker.upperBound, 1325, accuracy: 3)
        XCTAssertEqual(scan.powerDepth, 4)
    }

    /// The 9 Pro Fold's cover has a flat right edge (x 1235 from y 245 to
    /// 2309) and the tablet no bulges at all: no buttons.
    func testTheFlatFoldCoverAndTheTabletHaveNoButtons() throws {
        XCTAssertEqual(SkinButtonScanner.scan(artworkURL: try artworkURL("pixel_9_pro_fold/closed")), [])
        XCTAssertEqual(SkinButtonScanner.scan(artworkURL: try artworkURL("pixel_tablet")), [])
    }

    /// The whole installed set against the snapshot.
    func testTheInstalledSkinsScanToTheirSnapshot() throws {
        let artwork = try installedArtwork()
        XCTAssertGreaterThanOrEqual(artwork.count, 40, "expected the full SDK skin set")
        var seen: Set<String> = []
        for (skin, url) in artwork {
            let buttons = SkinButtonScanner.scan(artworkURL: url)
            if let expected = Self.accepted[skin] {
                seen.insert(skin)
                XCTAssertEqual(Scan(buttons), expected, skin)
            } else {
                XCTAssertEqual(buttons, [], "\(skin) is not in the snapshot but scans to buttons")
            }
        }
        // A snapshot skin that is no longer installed is only reported:
        // SDK updates add and drop skins.
        let missing = Set(Self.accepted.keys).subtracting(seen)
        if !missing.isEmpty {
            print("SkinButtonsTests: snapshot skins not installed: \(missing.sorted())")
        }
    }

    // MARK: - Button art

    /// The artwork drawn into premultiplied sRGB RGBA, independently of the
    /// code under test.
    private func rgba(_ url: URL) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = try draw(image.width, image.height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (bytes, image.width, image.height)
    }

    /// Runs `body` on a premultiplied sRGB RGBA context and returns its
    /// bytes, top row first.
    private func draw(_ width: Int, _ height: Int, _ body: (CGContext) -> Void) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .none
            body(context)
        }
        return bytes
    }

    /// The rest state: every sprite at its rect, the base over them.
    private func rest(_ art: SkinButtonArt, width: Int, height: Int) throws -> [UInt8] {
        try draw(width, height) { context in
            func place(_ image: CGImage, at rect: CGRect) {
                // Top-left artwork rects into CoreGraphics' y-up space.
                context.draw(image, in: CGRect(
                    x: rect.minX,
                    y: CGFloat(height) - rect.maxY,
                    width: rect.width,
                    height: rect.height
                ))
            }
            for (key, sprite) in art.sprites {
                place(sprite, at: art.spriteRects[key]!)
            }
            place(art.base, at: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The art of one skin: the sprites under the base give back the
    /// artwork's bytes exactly, and the base is cleared where the sprites
    /// are.
    private func assertArtRestoresTheArtwork(_ skin: String, url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let buttons = SkinButtonScanner.scan(artworkURL: url)
        XCTAssertEqual(buttons.count, 3, skin, file: file, line: line)
        let art = try XCTUnwrap(SkinButtonArt.make(artworkURL: url, buttons: buttons), skin, file: file, line: line)
        let original = try rgba(url)
        XCTAssertEqual(art.base.width, original.width, skin, file: file, line: line)
        XCTAssertEqual(art.base.height, original.height, skin, file: file, line: line)
        XCTAssertEqual(art.buttons, buttons, file: file, line: line)
        XCTAssertEqual(Set(art.sprites.keys), Set(HardwareKey.allCases), skin, file: file, line: line)
        XCTAssertEqual(Set(art.stems.keys), Set(HardwareKey.allCases), skin, file: file, line: line)

        let restored = try rest(art, width: original.width, height: original.height)
        XCTAssertEqual(restored.count, original.bytes.count, file: file, line: line)
        let identical = restored.withUnsafeBytes { restoredBytes in
            original.bytes.withUnsafeBytes { originalBytes in
                memcmp(restoredBytes.baseAddress, originalBytes.baseAddress, min(restoredBytes.count, originalBytes.count)) == 0
            }
        }
        XCTAssertTrue(identical, "\(skin): the rest state differs from the artwork", file: file, line: line)

        let base = try draw(original.width, original.height) { context in
            context.draw(art.base, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        }
        for button in buttons {
            let sprite = try XCTUnwrap(art.spriteRects[button.key], file: file, line: line)
            let stem = try XCTUnwrap(art.stems[button.key], file: file, line: line)
            XCTAssertEqual(stem.width, 1, file: file, line: line)
            XCTAssertEqual(stem.height, Int(sprite.height), file: file, line: line)
            XCTAssertEqual(art.sprites[button.key]?.width, Int(sprite.width), file: file, line: line)
            XCTAssertTrue(sprite.contains(button.rect), "\(skin) \(button.key)", file: file, line: line)
            XCTAssertEqual(Int(sprite.minX), button.baseline + 1, file: file, line: line)
            XCTAssertEqual(Int(sprite.maxX), original.width, "cleared to the artwork's right edge", file: file, line: line)
            var baseAlpha = 0
            var artworkAlpha = 0
            for y in Int(sprite.minY)..<Int(sprite.maxY) {
                for x in Int(sprite.minX)..<Int(sprite.maxX) {
                    baseAlpha += Int(base[(y * original.width + x) * 4 + 3])
                    artworkAlpha += Int(original.bytes[(y * original.width + x) * 4 + 3])
                }
            }
            XCTAssertEqual(baseAlpha, 0, "\(skin) \(button.key): the base keeps nothing of the button", file: file, line: line)
            XCTAssertGreaterThan(artworkAlpha, 0, "\(skin) \(button.key): the sprite holds the button", file: file, line: line)
        }
        // The power sprite reaches 3 rows past its bulge; the rocker's two
        // sprites meet at its midpoint and share its margins.
        let power = try XCTUnwrap(buttons.first { $0.key == .power })
        XCTAssertEqual(art.spriteRects[.power]?.minY, power.rect.minY - 3, file: file, line: line)
        XCTAssertEqual(art.spriteRects[.power]?.maxY, power.rect.maxY + 3, file: file, line: line)
        XCTAssertEqual(art.spriteRects[.volumeUp]?.maxY, art.spriteRects[.volumeDown]?.minY, file: file, line: line)
    }

    func testTheButtonArtRestoresTheArtworkExactly() throws {
        for skin in ["pixel_10_pro", "pixel_8", "pixel_9_pro_fold/default"] {
            try assertArtRestoresTheArtwork(skin, url: try artworkURL(skin))
        }
    }

    /// Skins without buttons get no art.
    func testThereIsNoArtWithoutButtons() throws {
        for skin in ["pixel_9_pro_fold/closed", "pixel_tablet"] {
            let url = try artworkURL(skin)
            XCTAssertNil(SkinButtonArt.make(artworkURL: url, buttons: SkinButtonScanner.scan(artworkURL: url)), skin)
        }
    }

    /// Every accepted installed skin, with `DHP_SKIN_ART_SWEEP=1` (a
    /// few seconds of decoding).
    func testTheButtonArtOfEveryAcceptedSkinRestoresItsArtwork() throws {
        guard ProcessInfo.processInfo.environment["DHP_SKIN_ART_SWEEP"] == "1" else {
            throw XCTSkip("set DHP_SKIN_ART_SWEEP=1 to split every accepted installed skin")
        }
        var checked = 0
        for (skin, url) in try installedArtwork() where Self.accepted[skin] != nil {
            try assertArtRestoresTheArtwork(skin, url: url)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    // MARK: - The rule (generated input, not device output)

    /// Scans a 60 × 1000 alpha plane whose body's right edge sits at x 29 on
    /// every row, with `bulges` reaching `depth` px further on their rows
    /// (255 inside the body, 0 outside).
    private func scan(_ bulges: [(rows: ClosedRange<Int>, depth: Int)]) -> [SkinHardwareButton] {
        let width = 60
        let height = 1000
        var alpha = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let reach = 29 + (bulges.first { $0.rows.contains(y) }?.depth ?? 0)
            for x in 0...reach {
                alpha[y * width + x] = 255
            }
        }
        return SkinButtonScanner.scan(alpha: alpha, width: width, height: height)
    }

    func testTwoBulgesTheUpperShorterAreSplitIntoThreeKeys() {
        XCTAssertEqual(scan([(300...339, 6), (380...459, 8)]), [
            SkinHardwareButton(key: .power, group: 0, rect: CGRect(x: 30, y: 300, width: 6, height: 40), baseline: 29, depth: 6),
            SkinHardwareButton(key: .volumeUp, group: 1, rect: CGRect(x: 30, y: 380, width: 8, height: 40), baseline: 29, depth: 8),
            SkinHardwareButton(key: .volumeDown, group: 1, rect: CGRect(x: 30, y: 420, width: 8, height: 40), baseline: 29, depth: 8),
        ])
        // An odd rocker gives its extra row to volume down.
        XCTAssertEqual(scan([(300...339, 6), (380...460, 8)]).map(\.rect.height), [40, 40, 41])
    }

    func testAnythingButTwoAcceptableBulgesGivesNoButtons() {
        XCTAssertEqual(scan([]), [], "a flat edge")
        XCTAssertEqual(scan([(300...339, 6)]), [], "one bulge")
        XCTAssertEqual(scan([(200...219, 6), (300...339, 6), (380...459, 6)]), [], "three bulges")
        XCTAssertEqual(scan([(300...379, 6), (400...439, 6)]), [], "the upper bulge is the longer")
        XCTAssertEqual(scan([(300...339, 6), (380...419, 6)]), [], "equal lengths")
        XCTAssertEqual(scan([(300...339, 6), (380...459, 13)]), [], "deeper than 12 px")
        XCTAssertEqual(scan([(300...339, 6), (380...459, 12)]).count, 3, "12 px is still a button")
    }

    func testShallowOrShortBumpsAreNotBulges() {
        // A 3 px bump or a 7-row one next to a real pair changes nothing.
        XCTAssertEqual(scan([(200...239, 3), (300...339, 6), (380...459, 8)]).count, 3)
        XCTAssertEqual(scan([(200...206, 9), (300...339, 6), (380...459, 8)]).count, 3)
        // 4 px deep and 8 rows long is the least that counts.
        XCTAssertEqual(scan([(200...207, 4), (300...339, 6), (380...459, 8)]), [], "a third bulge")
        XCTAssertEqual(scan([(300...307, 4), (380...459, 4)]).count, 3)
    }

    func testMalformedPlanesGiveNoButtons() {
        XCTAssertEqual(SkinButtonScanner.scan(alpha: [], width: 0, height: 0), [])
        XCTAssertEqual(SkinButtonScanner.scan(alpha: [255, 255], width: 2, height: 2), [], "too few bytes")
        XCTAssertEqual(SkinButtonScanner.scan(alpha: [UInt8](repeating: 0, count: 400), width: 20, height: 20), [])
        XCTAssertEqual(SkinButtonScanner.scan(artworkURL: URL(fileURLWithPath: "/nonexistent/back.webp")), [])
    }
}
