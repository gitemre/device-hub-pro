import XCTest
import SwiftUI
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The vector body is drawn twice from one plan: live by SwiftUI
/// (`VectorBodyBands`, on the stage) and into bitmaps by the Kit's
/// CoreGraphics renderer (`DeviceCompositionRenderer`, the stopped device's
/// hero and framed screenshots). The two must agree, so a device cannot
/// change shape or colour between the stage and its pictures: rendered at 2x
/// and laid over an opaque white canvas, outside the screen the mean
/// difference is at most 1/255 and no channel of any pixel differs by more
/// than 16/255 (the two rasterizers' anti-aliasing of the arcs).
///
/// Plans: the API 37 Pixel 9 Pro Fold emulator's real `dumpsys display`
/// capture (inner panel: foldableInner, radius 85; cover: phone, radius
/// 115), and, as generated input, not device output, a phone and a tablet
/// that report nothing (square corners, the densities passed in). Each at
/// the scale the 1300x866 stage fits it at, and at a compact window's
/// default size (0.17 pt per pixel), where the 1-pixel band clamp holds the
/// rim and highlight.
@MainActor
final class VectorBodyParityTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/adb-core/shell-dumpsys-display.txt")

    private static let pixelScale: CGFloat = 2

    func testTheLiveBandsMatchTheKitRenderer() throws {
        let shapes = DisplayShape.parse(dumpsysDisplay: try String(contentsOf: Self.fixture, encoding: .utf8))
        XCTAssertEqual(shapes.count, 2, "the fold lists its two panels")
        let plans: [(String, DeviceComposition)] = [
            ("fold inner", DeviceCompositionPlanner.vector(
                screen: CGSize(width: 2076, height: 2152), displays: shapes, fallbackDensityDpi: nil, hingeCount: 1, quarterTurns: 0
            )),
            ("fold cover", DeviceCompositionPlanner.vector(
                screen: CGSize(width: 1080, height: 2424), displays: shapes, fallbackDensityDpi: nil, hingeCount: 1, quarterTurns: 0
            )),
            ("phone, nothing reported", DeviceCompositionPlanner.vector(
                screen: CGSize(width: 1080, height: 2400), displays: [], fallbackDensityDpi: 420, quarterTurns: 0
            )),
            ("tablet, nothing reported", DeviceCompositionPlanner.vector(
                screen: CGSize(width: 2560, height: 1600), displays: [], fallbackDensityDpi: 320, quarterTurns: 0
            )),
        ]
        guard case .vector(let inner) = plans[0].1.body, case .vector(let tablet) = plans[3].1.body else {
            return XCTFail("vector plans")
        }
        XCTAssertEqual(inner.family, .foldableInner)
        XCTAssertEqual(tablet.family, .tablet)

        for (name, plan) in plans {
            let stageFit = PoseFit.scale(angle: 0, nativeSize: plan.layoutSize, box: CGSize(width: 1284, height: 850))
            for pointsPerUnit in [stageFit, 0.17] {
                try assertParity(plan, pointsPerUnit: pointsPerUnit, "\(name) at \(pointsPerUnit) pt/px")
            }
        }
    }

    private func assertParity(_ plan: DeviceComposition, pointsPerUnit: CGFloat, _ context: String) throws {
        let placed = plan.placed(pointsPerUnit: pointsPerUnit, pixelScale: Self.pixelScale)
        let renderer = ImageRenderer(content: VectorBodyBands(bands: placed.bands)
            .frame(width: placed.size.width, height: placed.size.height, alignment: .topLeading))
        renderer.scale = Self.pixelScale
        let live = try XCTUnwrap(renderer.cgImage, "\(context): live")
        let kit = try XCTUnwrap(
            DeviceCompositionRenderer.render(plan, pixelsPerUnit: pointsPerUnit * Self.pixelScale) { _, _ in },
            "\(context): kit"
        )
        let width = min(live.width, kit.width)
        let height = min(live.height, kit.height)
        XCTAssertLessThanOrEqual(abs(live.width - kit.width), 1, context)
        XCTAssertLessThanOrEqual(abs(live.height - kit.height), 1, context)
        let livePixels = try OverWhite(live, width: width, height: height)
        let kitPixels = try OverWhite(kit, width: width, height: height)

        // The screen, where the kit also fills the cutout and the live body
        // leaves that to the video's layer, in pixels, grown by one.
        let screen = CGRect(
            x: placed.screen.minX * Self.pixelScale,
            y: placed.screen.minY * Self.pixelScale,
            width: placed.screen.width * Self.pixelScale,
            height: placed.screen.height * Self.pixelScale
        ).insetBy(dx: -1, dy: -1)

        var total = 0.0
        var count = 0
        var worst = (difference: 0, x: 0, y: 0)
        var bodyPixels = 0
        for y in 0..<height {
            for x in 0..<width where !screen.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                let offset = (y * width + x) * 4
                if kitPixels.bytes[offset] < 250 { bodyPixels += 1 }
                for channel in 0..<3 {
                    let difference = abs(Int(livePixels.bytes[offset + channel]) - Int(kitPixels.bytes[offset + channel]))
                    total += Double(difference)
                    count += 1
                    if difference > worst.difference { worst = (difference, x, y) }
                }
            }
        }
        XCTAssertGreaterThan(bodyPixels, 1000, "\(context): the body was drawn, not only the white canvas")
        let mean = total / Double(max(count, 1))
        XCTAssertLessThanOrEqual(mean, 1, "\(context): mean difference (levels of 255)")
        XCTAssertLessThanOrEqual(
            worst.difference,
            16,
            "\(context): the largest difference, at pixel (\(worst.x), \(worst.y))"
        )
    }

    /// An image drawn over opaque white into 8-bit sRGB RGBA, row 0 at the
    /// top, cropped to `width` x `height` from its top-left corner.
    private struct OverWhite {
        let bytes: [UInt8]

        init(_ image: CGImage, width: Int, height: Int) throws {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ) else {
                    return false
                }
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                // y up: the image's top-left corner at the canvas's.
                context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
                return true
            }
            XCTAssertTrue(drawn)
            self.bytes = bytes
        }
    }
}
