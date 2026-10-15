import Foundation
import XCTest

/// Where the controls sit (Shared/ControlAreas.swift). The safe areas,
/// layouts and bands are the ones the iOS 27.1 iPhone Duo simulator reported
/// to Daybreak (`--log-readings`): the deck never crosses the fold's 40 pt
/// band, and stays inside the safe area.
final class ControlAreasTests: XCTestCase {
    /// The 951 × 669 book: the vertical bar on the trailing edge, the band
    /// 455.5,0,40,669. The deck sits on the trailing page.
    func testTheBooksDeckIsOnTheTrailingPage() {
        let areas = ControlAreas(
            safeArea: EdgePadding(top: 24, leading: 0, bottom: 34, trailing: 84),
            layout: .book(spineX: 475.5, halfWidth: 20, horizonY: 669 * 0.64)
        )
        XCTAssertEqual(areas.safe, EdgePadding(top: 40, leading: 16, bottom: 50, trailing: 100))
        XCTAssertEqual(areas.deck, EdgePadding(top: 40, leading: 511.5, bottom: 50, trailing: 100))
        XCTAssertGreaterThanOrEqual(areas.deck.leading, 455.5 + 40)
    }

    /// The 669 × 951 laptop: top and bottom bars, the band 0,455.5,669,40.
    /// The deck sits on the base, the lid shows only the sky.
    func testTheLaptopsDeckIsOnTheBase() {
        let areas = ControlAreas(
            safeArea: EdgePadding(top: 82, leading: 0, bottom: 82, trailing: 0),
            layout: .lidAndBase(creaseY: 475.5, halfHeight: 20)
        )
        XCTAssertEqual(areas.safe, EdgePadding(top: 98, leading: 16, bottom: 98, trailing: 16))
        XCTAssertEqual(areas.deck, EdgePadding(top: 511.5, leading: 16, bottom: 98, trailing: 16))
        XCTAssertGreaterThanOrEqual(areas.deck.top, 455.5 + 40)
        XCTAssertLessThan(areas.deck.top, 951 - areas.deck.bottom)
    }

    /// The 678 × 466 tent cover has no fold: the deck has the safe area.
    func testTheCoverHasNoBand() {
        let areas = ControlAreas(
            safeArea: EdgePadding(top: 24, leading: 0, bottom: 34, trailing: 84),
            layout: .single(horizonY: 466 * 0.64)
        )
        XCTAssertEqual(areas.deck, areas.safe)
        XCTAssertEqual(areas.safe, EdgePadding(top: 40, leading: 16, bottom: 50, trailing: 100))
    }

    /// Made up: a safe area reaching past the band still wins.
    func testTheSafeAreaWinsOverTheBand() {
        let areas = ControlAreas(
            safeArea: EdgePadding(top: 0, leading: 600, bottom: 0, trailing: 0),
            layout: .book(spineX: 475.5, halfWidth: 20, horizonY: 428)
        )
        XCTAssertEqual(areas.deck.leading, 616)
    }
}
