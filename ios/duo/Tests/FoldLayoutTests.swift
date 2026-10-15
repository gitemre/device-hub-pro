import Foundation
import XCTest

/// Where the fold lies (Shared/FoldLayout.swift), from the division regions
/// the iOS 27.1 iPhone Duo simulator (Xcode 27.1 RC, 27A9275) reported to
/// Daybreak launched with `--log-readings` (the `regions` of its `layout`
/// lines; the first builds wrote them as `swiftui.division` lines). The
/// frames, their `isActive` and the window sizes are ones it read;
/// `testTheFirstValidRegionWins` and `testHalfPointRoundingIsTolerated` put
/// made-up regions beside them, to pin the rules at their edges.
final class FoldLayoutTests: XCTestCase {
    private let bookBand = FoldRegion(x: 455.5, y: 0, width: 40, height: 669, isActive: true)
    private let laptopBand = FoldRegion(x: 0, y: 455.5, width: 669, height: 40, isActive: true)

    func testBookAndOpenFlatPutTheSpineOnTheFold() {
        let book = FoldLayout.layout(width: 951, height: 669, regularWidth: true, regions: [bookBand])
        XCTAssertEqual(book, .book(spineX: 475.5, halfWidth: 20, horizonY: 669 * 0.64))
        XCTAssertTrue(bookBand.isVertical)
        // Flat open the region is inactive, and still the fold.
        var open = bookBand
        open.isActive = false
        XCTAssertEqual(FoldLayout.layout(width: 951, height: 669, regularWidth: true, regions: [open]), book)
    }

    func testLaptopPutsTheHorizonOnTheCrease() {
        XCTAssertFalse(laptopBand.isVertical)
        XCTAssertEqual(
            FoldLayout.layout(width: 669, height: 951, regularWidth: true, regions: [laptopBand]),
            .lidAndBase(creaseY: 475.5, halfHeight: 20)
        )
        // Inactive for up to 2 s after the window arrives on the inner panel.
        var arriving = laptopBand
        arriving.isActive = false
        XCTAssertEqual(
            FoldLayout.layout(width: 669, height: 951, regularWidth: true, regions: [arriving]),
            .lidAndBase(creaseY: 475.5, halfHeight: 20)
        )
    }

    func testCoverHasNoFold() {
        XCTAssertEqual(FoldLayout.layout(width: 466, height: 678, regularWidth: false, regions: []), .single(horizonY: 678 * 0.64))
        XCTAssertEqual(FoldLayout.layout(width: 678, height: 466, regularWidth: false, regions: []), .single(horizonY: 466 * 0.64))
    }

    /// The passes right after an inner → cover move, in the 678 × 466 tent
    /// cover: the inner window's bands, unturned or moved off the window,
    /// some still active. Out of the bounds, so ignored even at regular width.
    func testStaleRegionsOnTheCoverAreIgnored() {
        let stale = [
            FoldRegion(x: 182.5, y: 0, width: 40, height: 669, isActive: true),
            FoldRegion(x: 455.5, y: -203, width: 40, height: 669, isActive: false),
            FoldRegion(x: 0, y: 455.5, width: 669, height: 40, isActive: true),
        ]
        for region in stale {
            for regularWidth in [false, true] {
                XCTAssertEqual(
                    FoldLayout.layout(width: 678, height: 466, regularWidth: regularWidth, regions: [region]),
                    .single(horizonY: 466 * 0.64),
                    "\(region), regular width \(regularWidth)"
                )
            }
        }
    }

    /// The pass after the open phone turns: the old band in the turned
    /// window. Inside the bounds, but it does not cross the window, so it is
    /// not the fold (laptop must not get a spine, nor book a crease).
    func testTheUnturnedBandAfterARotationIsIgnored() {
        XCTAssertEqual(
            FoldLayout.layout(width: 669, height: 951, regularWidth: true, regions: [bookBand]),
            .single(horizonY: 951 * 0.64)
        )
        var horizontal = laptopBand
        horizontal.isActive = false
        XCTAssertEqual(
            FoldLayout.layout(width: 951, height: 669, regularWidth: true, regions: [horizontal]),
            .single(horizonY: 669 * 0.64)
        )
        // The stale band first, the turned one next: the valid one wins.
        XCTAssertEqual(
            FoldLayout.layout(width: 669, height: 951, regularWidth: true, regions: [bookBand, laptopBand]),
            .lidAndBase(creaseY: 475.5, halfHeight: 20)
        )
    }

    func testCompactWidthIgnoresEvenAValidRegion() {
        XCTAssertEqual(
            FoldLayout.layout(width: 951, height: 669, regularWidth: false, regions: [bookBand]),
            .single(horizonY: 669 * 0.64)
        )
    }

    /// Made up: the simulator never reported two valid regions at once.
    func testTheFirstValidRegionWins() {
        let other = FoldRegion(x: 100, y: 0, width: 40, height: 669, isActive: true)
        XCTAssertEqual(
            FoldLayout.layout(width: 951, height: 669, regularWidth: true, regions: [bookBand, other]),
            .book(spineX: 475.5, halfWidth: 20, horizonY: 669 * 0.64)
        )
    }

    /// Made up: the ±0.5 pt tolerance for frames rounded to half points,
    /// and a region a whole point outside.
    func testHalfPointRoundingIsTolerated() {
        let rounded = FoldRegion(x: 455.5, y: -0.5, width: 40, height: 669.5, isActive: true)
        XCTAssertEqual(
            FoldLayout.layout(width: 951, height: 669, regularWidth: true, regions: [rounded]),
            .book(spineX: 475.5, halfWidth: 20, horizonY: 669 * 0.64)
        )
        let off = FoldRegion(x: 455.5, y: -1, width: 40, height: 669, isActive: true)
        XCTAssertEqual(
            FoldLayout.layout(width: 951, height: 669, regularWidth: true, regions: [off]),
            .single(horizonY: 669 * 0.64)
        )
    }
}
