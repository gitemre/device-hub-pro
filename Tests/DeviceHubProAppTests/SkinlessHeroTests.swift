import XCTest
import AppKit
import SwiftUI
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The stopped skinless AVD's hero: `AvdDetailView` plans the device's
/// vector body from its `config.ini` and the shapes it last reported, and
/// `SkinHero` draws it where a skin would be.
///
/// The config is the real `Pixel_9_Pro_Fold` AVD's
/// (`Fixtures/api37-emulator/logcat-sdk-apk/avd/Pixel_9_Pro_Fold.avd`:
/// 2076x2152, `hw.lcd.density` 390, one hinge), copied into a temporary AVD
/// home; its `skin.*` keys are not read here. The shapes are the same
/// emulator's `dumpsys display` (inner panel radius 85, its punch hole at
/// (1987.5, 80)). The numbers are `ChromeGeometryTests`': a 4.3 mm
/// (66.024 px) foldable body, 2208.047 x 2284.047, outer radius 151.024.
@MainActor
final class SkinlessHeroTests: XCTestCase {
    private static let kitFixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator", isDirectory: true)

    private static func foldShapes() throws -> [DisplayShape] {
        let dump = kitFixtures.appendingPathComponent("adb-core/shell-dumpsys-display.txt")
        return DisplayShape.parse(dumpsysDisplay: try String(contentsOf: dump, encoding: .utf8))
    }

    /// A temporary AVD home holding the fold's real `config.ini` as
    /// `Pixel_9_Pro_Fold.avd` (no `.ini` pointer: the emulator's default
    /// `<home>/<name>.avd`).
    private func foldAvdHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkinlessHeroTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let content = home.appendingPathComponent("Pixel_9_Pro_Fold.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Self.kitFixtures.appendingPathComponent("logcat-sdk-apk/avd/Pixel_9_Pro_Fold.avd/config.ini"),
            to: content.appendingPathComponent("config.ini")
        )
        return home
    }

    private struct NotAVectorBody: Error {}

    private func vectorBody(_ plan: DeviceComposition) throws -> DeviceComposition.VectorBody {
        guard case let .vector(body) = plan.body else { throw NotAVectorBody() }
        return body
    }

    // MARK: - The plan

    /// From the config alone: the foldable inner screen's body around a
    /// square screen (by design: no corner is invented) with no hole.
    /// With the shapes the AVD last reported: its 85 px corner, concentric
    /// 151.024 px body corner and its upright hole.
    func testAStoppedSkinlessFoldPlansItsInnerBodyFromItsConfig() throws {
        let home = try foldAvdHome()

        let bare = try XCTUnwrap(AvdDetailView.vectorPlan(avdName: "Pixel_9_Pro_Fold", avdHome: home, shapes: []))
        XCTAssertEqual(try vectorBody(bare).family, .foldableInner)
        XCTAssertEqual(try vectorBody(bare).bezel, 66.024, accuracy: 0.01)
        XCTAssertEqual(bare.layoutSize.width, 2208.047, accuracy: 0.01)
        XCTAssertEqual(bare.layoutSize.height, 2284.047, accuracy: 0.01)
        XCTAssertEqual(bare.screenRect.size, CGSize(width: 2076, height: 2152))
        XCTAssertEqual(bare.screenCorner, ScreenCorner(radius: 0, source: .none))
        XCTAssertNil(bare.cutout)

        let stored = try XCTUnwrap(AvdDetailView.vectorPlan(
            avdName: "Pixel_9_Pro_Fold",
            avdHome: home,
            shapes: try Self.foldShapes()
        ))
        XCTAssertEqual(try vectorBody(stored).family, .foldableInner)
        XCTAssertEqual(stored.screenCorner, ScreenCorner(radius: 85, source: .device))
        XCTAssertEqual(try vectorBody(stored).outerRadius, 151.024, accuracy: 0.01)
        XCTAssertEqual(stored.cutout?.quarterTurns, 0)
        XCTAssertEqual(stored.cutout?.naturalSize, CGSize(width: 2076, height: 2152))
    }

    /// An AVD whose config cannot be read (here none at all) plans nothing:
    /// the hero keeps its placeholder card.
    func testAnAvdWithoutAConfigPlansNothing() throws {
        let home = try foldAvdHome()
        XCTAssertNil(AvdDetailView.vectorPlan(avdName: "No_Such_Avd", avdHome: home, shapes: []))
    }

    // MARK: - The hero

    /// Without a skin, the hero draws the plan's body: empty at its aspect
    /// ratio while it renders off the main thread, then the image.
    func testTheHeroDrawsTheVectorBodyWhenThereIsNoSkin() async throws {
        let plan = try XCTUnwrap(AvdDetailView.vectorPlan(
            avdName: "Pixel_9_Pro_Fold",
            avdHome: try foldAvdHome(),
            shapes: try Self.foldShapes()
        ))
        let rendered = RenderedPlans()
        let cache = SkinThumbnailCache(renderVector: { plan, height, scale in
            rendered.record(plan, onMain: Thread.isMainThread)
            return SkinThumbnail.renderVector(plan, height: height, scale: scale)
        })

        guard case let .pending(aspectRatio) = SkinHero.presentation(
            variant: nil,
            deviceShapes: [],
            vector: plan,
            cache: cache
        ) else {
            return XCTFail("the first read must not wait for the render")
        }
        XCTAssertEqual(aspectRatio, 2208.047 / 2284.047, accuracy: 0.0001)

        _ = await cache.renderedVectorImage(for: plan, height: SkinHero.deviceHeight)
        guard case let .image(image) = SkinHero.presentation(variant: nil, deviceShapes: [], vector: plan, cache: cache) else {
            return XCTFail("the rendered body")
        }
        XCTAssertEqual(image.size.height, SkinHero.deviceHeight, accuracy: 0.5)
        XCTAssertEqual(rendered.plans, [plan])
        XCTAssertEqual(rendered.onMain, [false])
    }

    /// A skin still wins over a vector plan, and with neither the hero shows
    /// its placeholder card ("nothing known").
    func testASkinWinsAndNothingKnownIsThePlaceholderCard() async throws {
        let plan = try XCTUnwrap(AvdDetailView.vectorPlan(avdName: "Pixel_9_Pro_Fold", avdHome: try foldAvdHome(), shapes: []))
        let rendered = RenderedPlans()
        let cache = SkinThumbnailCache(
            render: { _, height, scale, _ in SkinPreviewCacheTests.solidImage(width: Int(height * scale / 2), height: Int(height * scale)) },
            renderVector: { plan, _, _ in
                rendered.record(plan, onMain: Thread.isMainThread)
                return nil
            }
        )
        let variant = SkinVariant(id: "default", directory: URL(fileURLWithPath: "/nonexistent/skin"), layout: nil)
        _ = await cache.renderedImage(for: variant, height: SkinHero.deviceHeight)

        guard case .image = SkinHero.presentation(variant: variant, deviceShapes: [], vector: plan, cache: cache) else {
            return XCTFail("the skin's preview")
        }
        guard case .placeholder = SkinHero.presentation(variant: nil, deviceShapes: [], vector: nil, cache: cache) else {
            return XCTFail("the placeholder card")
        }
        XCTAssertTrue(rendered.plans.isEmpty, "no vector body is rendered beside a skin")
    }

    /// Drawn, the hero is the body, not the grey card: the plan's shape
    /// (2208.047 : 2284.047, 386.7 x `SkinHero.height` pt), the placeholder
    /// screen's light-blue wallpaper in the middle and the transparent
    /// canvas past the body's round corner. Rendered at 1x and 2x.
    func testTheDrawnHeroIsTheBody() async throws {
        let plan = try XCTUnwrap(AvdDetailView.vectorPlan(
            avdName: "Pixel_9_Pro_Fold",
            avdHome: try foldAvdHome(),
            shapes: try Self.foldShapes()
        ))
        _ = await SkinThumbnailCache.shared.renderedVectorImage(for: plan, height: SkinHero.deviceHeight)

        for scale: CGFloat in [1, 2] {
            let renderer = ImageRenderer(content: SkinHero(variant: nil, vector: plan).frame(height: SkinHero.height))
            renderer.scale = scale
            let image = try XCTUnwrap(renderer.cgImage, "\(scale)x")
            XCTAssertEqual(CGFloat(image.height), SkinHero.height * scale, accuracy: 1, "\(scale)x")
            let expectedWidth = SkinHero.deviceHeight * 2208.047 / 2284.047
            XCTAssertEqual(CGFloat(image.width), expectedWidth * scale, accuracy: 1.5, "\(scale)x")
            let middle = try Self.pixel(image, x: image.width / 2, y: image.height / 2)
            XCTAssertEqual(middle[3], 255, "\(scale)x")
            // The light-blue placeholder reads
            // 61–87 red at its darkest/lightest; the grey card's is 60–170
            // with r≈g≈b, so blue-dominance (below) is the real test.
            XCTAssertLessThan(middle[0], 110, "the wallpaper, not the grey card, at \(scale)x: \(middle)")
            XCTAssertGreaterThan(Int(middle[2]), Int(middle[0]) + 10, "blue: \(middle) at \(scale)x")
            XCTAssertLessThan(try Self.pixel(image, x: 0, y: 0)[3], 128, "past the body's corner at \(scale)x")
        }
    }

    /// The stopped AVD's page, hosted: its `.task` plans the skinless AVD's
    /// body from the config (and the shapes the library holds for it) and
    /// the hero draws it, the placeholder's light-blue wallpaper somewhere
    /// down the stage's centre column, where the grey card would otherwise
    /// be. Not a fixed offset from the top: the page's whole group (hero,
    /// name, subtitle, Start) is centred vertically in the stage
    /// follow-up, 2026-09-28), so the hero's own position depends on the
    /// group's total height. Pixels are read at the hosting window's own
    /// backing scale.
    func testTheDetailPagePlansAndDrawsASkinlessAvdsBody() async throws {
        let home = try foldAvdHome()
        let model = AppModel.testing()
        model.catalog.avdCards = [AvdCard(
            name: "Pixel_9_Pro_Fold",
            displayName: "Pixel 9 Pro Fold",
            target: nil,
            skin: nil,
            isRunning: false,
            serial: nil
        )]
        model.mirror.displayShapes.record(try Self.foldShapes(), forAvd: "Pixel_9_Pro_Fold")
        let size = CGSize(width: 600, height: 720)
        let host = NSHostingView(rootView: AvdDetailView(avdName: "Pixel_9_Pro_Fold", avdHome: home).environment(model).environment(model.workspace))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        // The light-blue placeholder reads 61–87 red;
        // blue-dominance (below) is what actually rules out the grey card.
        func isWallpaper(_ p: [UInt8]) -> Bool { p[0] < 110 && Int(p[2]) > Int(p[0]) + 10 }

        let deadline = ContinuousClock.now + .seconds(5)
        var found: [UInt8]?
        repeat {
            try? await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            found = try Self.hostedColumnMatch(host, x: size.width / 2, matching: isWallpaper)
        } while found == nil && ContinuousClock.now < deadline
        let centre = try XCTUnwrap(found, "the body's wallpaper was never drawn")
        XCTAssertLessThan(centre[0], 110, "the body's wallpaper, not the grey card: \(centre)")
        XCTAssertGreaterThan(Int(centre[2]), Int(centre[0]) + 10, "blue: \(centre)")
    }

    /// Scans column `x` (points) of `view`'s rendered bitmap, top to bottom,
    /// for the first pixel matching `predicate`, drawn at its window's own
    /// backing scale as sRGB RGBA; nil if none matches.
    private static func hostedColumnMatch(
        _ view: NSView,
        x: CGFloat,
        matching predicate: ([UInt8]) -> Bool
    ) throws -> [UInt8]? {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let scale = CGFloat(image.width) / view.bounds.width
        let px = Int(x * scale)
        for y in 0..<image.height {
            let p = try pixel(image, x: px, y: y)
            if predicate(p) { return p }
        }
        return nil
    }

    /// The premultiplied sRGB RGBA of `image`'s pixel at (`x`, `y`) from
    /// its top-left.
    private static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: 1,
                      height: 1,
                      bitsPerComponent: 8,
                      bytesPerRow: 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return bytes
    }
}

/// The vector plans a cache rendered, and on which thread.
private final class RenderedPlans: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(plan: DeviceComposition, onMain: Bool)] = []

    func record(_ plan: DeviceComposition, onMain: Bool) {
        lock.withLock { recorded.append((plan, onMain)) }
    }

    var plans: [DeviceComposition] { lock.withLock { recorded.map(\.plan) } }
    var onMain: [Bool] { lock.withLock { recorded.map(\.onMain) } }
}
