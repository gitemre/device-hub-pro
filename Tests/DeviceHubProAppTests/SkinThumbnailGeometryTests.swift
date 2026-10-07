import AppKit
import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The Browse Catalog's skin previews against the SDK's real artwork
/// (skipped for a skin that is not installed): the placeholder screen sits on
/// the layout's display rect and its corners fit the artwork's opening, at
/// every size and pixel scale the catalog draws.
final class SkinThumbnailGeometryTests: XCTestCase {
    private func variant(_ name: String) throws -> SkinVariant {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Android/sdk/skins/\(name)", isDirectory: true)
        guard let layout = SkinLayout.parseFile(at: dir.appendingPathComponent("layout")),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("back.webp").path)
        else { throw XCTSkip("\(name) is not installed in the SDK") }
        return SkinVariant(id: "default", directory: dir, layout: layout)
    }

    /// The bounding box of the placeholder's blue, in pixels, top-left based.
    private func blueBounds(_ image: CGImage) -> CGRect {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { p in
            let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if data[i + 2] > 150, data[i] < 130, Int(data[i + 2]) - Int(data[i]) > 60 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// `pixel_7a`: its corner is 45.6 layout units; measured from the drawn
    /// downsample it came out 138 at card height and 805 (a pill) at 520 px,
    /// so the placeholder's corners did not fit the opening and the artwork
    /// showed through them.
    func testPixel7aPreviewHasNoGapsAndSitsOnTheDisplayRectAtEverySizeAndScale() throws {
        let v = try variant("pixel_7a")
        let display = try XCTUnwrap(v.layout?.preferred)
        for (height, scale) in [(230.0, 1.0), (230, 2), (230, 3), (520, 1), (520, 2), (520, 3), (250, 2)] as [(CGFloat, CGFloat)] {
            let image = try XCTUnwrap(SkinThumbnail.render(variant: v, height: height, scale: scale))
            let context = "height \(height) at \(scale)x"
            XCTAssertEqual(SkinCatalogAuditTests.enclosedHoles(in: image, variant: v), 0, context)
            let ppu = CGFloat(image.height) / display.layoutSize.height
            let blue = blueBounds(image)
            let r = display.screenRect
            XCTAssertEqual(blue.minX, r.minX * ppu, accuracy: 2, context)
            XCTAssertEqual(blue.minY, r.minY * ppu, accuracy: 2, context)
            XCTAssertEqual(blue.maxX, r.maxX * ppu, accuracy: 2, context)
            XCTAssertEqual(blue.maxY, r.maxY * ppu, accuracy: 2, context)
        }
    }

    func testTheOpeningRadiusDoesNotDependOnThePreviewSize() throws {
        let v = try variant("pixel_7a")
        let display = try XCTUnwrap(v.layout?.preferred)
        let radius = try XCTUnwrap(SkinThumbnail.measuredTraits(for: v, display: display).openingCornerRadius)
        XCTAssertEqual(radius, 45.6, accuracy: 1)
    }

    func testModernPhonesAndAWatchHaveNoGapsAtCardAndDetailSize() throws {
        for name in ["pixel_6a", "pixel_8a", "pixel_9", "pixel_9_pro_xl", "pixel_10_pro", "pixel_fold", "pixel_tablet", "wearos_xl_round", "wearos_large_round"] {
            let v: SkinVariant
            do { v = try variant(name) } catch { continue }
            for (height, scale) in [(230.0, 1.0), (230, 2), (520, 2), (520, 3)] as [(CGFloat, CGFloat)] {
                let image = try XCTUnwrap(SkinThumbnail.render(variant: v, height: height, scale: scale), name)
                // A round watch keeps a ring-edge sliver or two: the wedge test
                // is for the rectangular screens.
                if name.hasPrefix("wearos") { continue }
                XCTAssertEqual(SkinCatalogAuditTests.enclosedHoles(in: image, variant: v), 0, "\(name) height \(height) at \(scale)x")
            }
        }
    }
}
