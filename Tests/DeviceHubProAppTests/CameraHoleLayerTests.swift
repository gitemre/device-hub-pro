import XCTest
import SwiftUI
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The skin's camera hole stays above the live picture. A skin whose
/// `layout` declares `cutout hole` (the Pixel 10 Pro, the 10 Pro Fold's cover)
/// has its foreground mask, which draws the hole, drawn over the video; a skin
/// without the declaration (the 9 Pro Fold's opened screen) is unchanged.
/// Reads the installed SDK's skins in place (skipped without it).
@MainActor
final class CameraHoleLayerTests: XCTestCase {
    private func skin(_ name: String) throws -> ResolvedSkin {
        guard let skins = SkinLocator.skinsDirectory() else { throw XCTSkip("no Android SDK skins directory") }
        let entry = try XCTUnwrap(SkinResolver.catalog(skinsDirectory: skins).first { $0.name == name }, name)
        return ResolvedSkin(name: entry.name, directory: entry.directory, source: .skinName, variants: entry.variants)
    }

    private func drawsMask(_ name: String, variant id: String = "default") throws -> (draws: Bool, hasMask: Bool, declares: Bool) {
        let skin = try skin(name)
        let variant = try XCTUnwrap(skin.variants.first { $0.id == id }, "\(name)/\(id)")
        let display = try XCTUnwrap(variant.layout?.preferred)
        let cache = SkinThumbnailCache.shared
        let art = cache.artwork(for: variant, display: display)
        let background = try XCTUnwrap(art.background, name)
        let plan = FramedMirrorView.plan(
            display: display,
            artworkPixelSize: background.artworkPixelSize,
            corner: ScreenCorner(radius: display.cornerRadius ?? 0, source: .declared),
            traits: cache.traits(for: variant, display: display),
            hasMask: art.mask != nil,
            hasOverlay: art.overlay != nil
        )
        return (FramedMirrorView.drawsForegroundMask(plan: plan, display: display), art.mask != nil, display.declaresCutout)
    }

    func testThePixel10ProKeepsItsCameraHoleAboveTheVideo() throws {
        let result = try drawsMask("pixel_10_pro")
        XCTAssertTrue(result.declares)
        XCTAssertTrue(result.hasMask)
        XCTAssertTrue(result.draws)
    }

    func testTheTenProFoldCoverKeepsItsHoleAndTheOpenedScreenIsUnchanged() throws {
        XCTAssertTrue(try drawsMask("pixel_10_pro_fold", variant: "closed").draws)
        let opened = try drawsMask("pixel_10_pro_fold")
        XCTAssertFalse(opened.declares)
        XCTAssertFalse(opened.draws)
    }

    func testThePixel9ProFoldIsUnchanged() throws {
        XCTAssertFalse(try drawsMask("pixel_9_pro_fold").draws)
    }
}
