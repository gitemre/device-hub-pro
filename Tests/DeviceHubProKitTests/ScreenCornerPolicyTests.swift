import CoreGraphics
import XCTest
@testable import DeviceHubProKit

/// `ScreenCornerPolicy` on real data: the device shapes are the API 37
/// Pixel 9 Pro Fold emulator's `dumpsys display` capture
/// (`Fixtures/api37-emulator/adb-core/shell-dumpsys-display.txt`: inner
/// panel radius 85 at 2076x2152, cover 115 at 1080x2424); the skin numbers
/// are the installed SDK skins' — display sizes and `corner_radius` from
/// their `layout` files, opening radii as `SkinRenderTraits.measure` reads
/// them from the artwork (checked on the real files by the app's
/// `ScreenCornerTests`).
final class ScreenCornerPolicyTests: XCTestCase {
    // `pixel_10_pro`: 1280x2856, `corner_radius 99`.
    private static let pixel10Pro = CGSize(width: 1280, height: 2856)
    private static let pixel10ProOpening: CGFloat = 180.08
    // `pixel_9_pro_fold/default` (inner): 2076x2152, no `corner_radius`.
    private static let foldInner = CGSize(width: 2076, height: 2152)
    private static let foldInnerOpening: CGFloat = 119.61
    // `pixel_9_pro_fold/closed` (cover): 1080x2424, `corner_radius 75`.
    private static let foldCover = CGSize(width: 1080, height: 2424)
    private static let foldCoverOpening: CGFloat = 147.26
    // `pixel_tablet`: 2560x1600, no `corner_radius`.
    private static let tablet = CGSize(width: 2560, height: 1600)
    private static let tabletOpening: CGFloat = 30.37

    private func shapes() throws -> [DisplayShape] {
        DisplayShape.parse(dumpsysDisplay: try AdbCoreFixtureTests.text("shell-dumpsys-display.txt"))
    }

    private func shape(matching size: CGSize) throws -> DisplayShape {
        try XCTUnwrap(DisplayShape.matching(frame: size, in: shapes()), "no display for \(size)")
    }

    // MARK: - The device's radius

    /// The fold's inner screen: the device reports 85, the skin declares
    /// nothing and its opening is 119.6. The device's radius wins (the old
    /// rule left this corner square).
    func testTheFoldInnerScreenTakesTheDevicesRadius() throws {
        let corner = ScreenCornerPolicy.corner(
            device: try shape(matching: Self.foldInner),
            displaySize: Self.foldInner,
            declaredRadius: nil,
            openingRadius: Self.foldInnerOpening,
            hasTransparentOpening: true
        )
        XCTAssertEqual(corner, ScreenCorner(radius: 85, source: .device))
    }

    /// The cover: the device's 115 wins over the declared 75, under the
    /// 147.3 opening.
    func testTheFoldCoverTakesTheDevicesRadiusOverTheDeclaredOne() throws {
        let corner = ScreenCornerPolicy.corner(
            device: try shape(matching: Self.foldCover),
            displaySize: Self.foldCover,
            declaredRadius: 75,
            openingRadius: Self.foldCoverOpening,
            hasTransparentOpening: true
        )
        XCTAssertEqual(corner, ScreenCorner(radius: 115, source: .device))
    }

    /// The streamed frame picks the panel: the same list gives the inner
    /// screen's 85 for an inner frame (either orientation) and the cover's
    /// 115 for a cover frame.
    func testTheStreamedFramePicksThePanelsRadius() throws {
        let shapes = try shapes()
        let inner = DisplayShape.matching(frame: CGSize(width: 2152, height: 2076), in: shapes)
        let cover = DisplayShape.matching(frame: CGSize(width: 1080, height: 2424), in: shapes)
        XCTAssertEqual(ScreenCornerPolicy.deviceRadius(of: inner, displaySize: Self.foldInner), 85)
        XCTAssertEqual(ScreenCornerPolicy.deviceRadius(of: cover, displaySize: Self.foldCover), 115)
    }

    /// A skin display sized apart from the device's resolution gets the
    /// device's radius at the skin's scale: the cover's 115 at 1080 px wide
    /// is 57.5 on a 540-unit-wide display of the same shape.
    func testTheDevicesRadiusIsScaledToTheSkinDisplay() throws {
        let cover = try shape(matching: Self.foldCover)
        let half = CGSize(width: 540, height: 1212)
        XCTAssertEqual(try XCTUnwrap(ScreenCornerPolicy.deviceRadius(of: cover, displaySize: half)), 57.5, accuracy: 1e-9)
        let corner = ScreenCornerPolicy.corner(
            device: cover,
            displaySize: half,
            declaredRadius: 37.5,
            openingRadius: Self.foldCoverOpening / 2,
            hasTransparentOpening: true
        )
        XCTAssertEqual(corner.radius, 57.5, accuracy: 1e-9)
        XCTAssertEqual(corner.source, .device)
    }

    // MARK: - The cap

    /// A device radius wider than the artwork's opening is lowered to it:
    /// the fold inner's 85 under the tablet's 30.4 opening (a pairing of two
    /// real numbers; no captured device reports a corner wider than its
    /// skin's opening).
    func testARadiusWiderThanTheOpeningIsCappedAtIt() {
        let corner = ScreenCornerPolicy.corner(
            deviceRadius: 85,
            displaySize: Self.tablet,
            declaredRadius: nil,
            openingRadius: Self.tabletOpening,
            hasTransparentOpening: true
        )
        XCTAssertEqual(corner, ScreenCorner(radius: Self.tabletOpening, source: .device, isCappedAtOpening: true))
    }

    /// The declared radius is capped the same way.
    func testTheDeclaredRadiusIsCappedToo() {
        let corner = ScreenCornerPolicy.corner(
            deviceRadius: nil,
            displaySize: Self.foldCover,
            declaredRadius: 200,
            openingRadius: Self.foldCoverOpening,
            hasTransparentOpening: true
        )
        XCTAssertEqual(corner, ScreenCorner(radius: Self.foldCoverOpening, source: .declared, isCappedAtOpening: true))
    }

    // MARK: - Without device data

    /// `pixel_10_pro` before any device data: the declared 99, under its
    /// 180.1 opening. (The running AVD is the fold; no 10 Pro was read.)
    func testThePixel10ProFallsBackToItsDeclaredRadius() {
        let corner = ScreenCornerPolicy.corner(
            device: nil,
            displaySize: Self.pixel10Pro,
            declaredRadius: 99,
            openingRadius: Self.pixel10ProOpening,
            hasTransparentOpening: true
        )
        XCTAssertEqual(corner, ScreenCorner(radius: 99, source: .declared))
    }

    /// The fold's cover before its first read: the declared 75.
    func testTheFoldCoverFallsBackToItsDeclaredRadius() {
        let corner = ScreenCornerPolicy.corner(
            device: nil,
            displaySize: Self.foldCover,
            declaredRadius: 75,
            openingRadius: Self.foldCoverOpening,
            hasTransparentOpening: true
        )
        XCTAssertEqual(corner, ScreenCorner(radius: 75, source: .declared))
    }

    /// `pixel_tablet` and the fold's inner screen declare nothing: the
    /// opening itself (30.4, 119.6), never the square corner the old rule
    /// drew.
    func testSkinsWithoutADeclaredRadiusFallBackToTheOpening() {
        for (size, opening) in [(Self.tablet, Self.tabletOpening), (Self.foldInner, Self.foldInnerOpening)] {
            let corner = ScreenCornerPolicy.corner(
                device: nil,
                displaySize: size,
                declaredRadius: nil,
                openingRadius: opening,
                hasTransparentOpening: true
            )
            XCTAssertEqual(corner, ScreenCorner(radius: opening, source: .opening), "\(size)")
        }
    }

    /// A device that prints no `RoundedCorners` (before API 31) is no data:
    /// the fold inner's line with the corners taken out falls back to the
    /// opening.
    func testADisplayWithoutRoundedCornersIsNoDeviceData() throws {
        var inner = try shape(matching: Self.foldInner)
        inner.topLeft = nil
        inner.topRight = nil
        inner.bottomRight = nil
        inner.bottomLeft = nil
        XCTAssertNil(ScreenCornerPolicy.deviceRadius(of: inner, displaySize: Self.foldInner))
        let corner = ScreenCornerPolicy.corner(
            device: inner,
            displaySize: Self.foldInner,
            declaredRadius: nil,
            openingRadius: Self.foldInnerOpening,
            hasTransparentOpening: true
        )
        XCTAssertEqual(corner.source, .opening)
    }

    /// Nothing at all: square corners.
    func testNothingKnownIsSquare() {
        let corner = ScreenCornerPolicy.corner(
            device: nil,
            displaySize: Self.foldInner,
            declaredRadius: nil,
            openingRadius: nil,
            hasTransparentOpening: true
        )
        XCTAssertEqual(corner, ScreenCorner(radius: 0, source: .none))
    }

    // MARK: - Legacy skins and round displays

    /// A legacy skin (opaque artwork over the screen, a mask on top) keeps
    /// its declared radius — `pixel_4_xl`'s 1440x3040 display declares none
    /// and stays square — unless the device reports one, which is then not
    /// capped: the skin has no opening to cap it with.
    func testLegacySkinsKeepTheirRadiusUnlessTheDeviceReportsOne() {
        let pixel4XL = CGSize(width: 1440, height: 3040)
        XCTAssertEqual(
            ScreenCornerPolicy.corner(
                deviceRadius: nil,
                displaySize: pixel4XL,
                declaredRadius: nil,
                openingRadius: nil,
                hasTransparentOpening: false
            ),
            ScreenCorner(radius: 0, source: .none)
        )
        XCTAssertEqual(
            ScreenCornerPolicy.corner(
                deviceRadius: nil,
                displaySize: pixel4XL,
                declaredRadius: 75,
                openingRadius: 40,
                hasTransparentOpening: false
            ),
            ScreenCorner(radius: 75, source: .declared),
            "an opening measured on opaque artwork caps nothing"
        )
        XCTAssertEqual(
            ScreenCornerPolicy.corner(
                deviceRadius: 115,
                displaySize: pixel4XL,
                declaredRadius: 75,
                openingRadius: 40,
                hasTransparentOpening: false
            ),
            ScreenCorner(radius: 115, source: .device)
        )
    }

    /// A round display is its inscribed circle, whatever the device or the
    /// skin says (`wearos_large_round`: 454x454).
    func testARoundDisplayIsItsInscribedCircle() {
        let corner = ScreenCornerPolicy.corner(
            deviceRadius: 30,
            displaySize: CGSize(width: 454, height: 454),
            declaredRadius: 12,
            openingRadius: 100,
            hasTransparentOpening: true,
            isRoundDisplay: true
        )
        XCTAssertEqual(corner, ScreenCorner(radius: 227, source: .roundDisplay))
    }

    /// No radius is wider than half the display's short side: CoreGraphics
    /// traps on such a rounded rect.
    func testTheRadiusNeverPassesHalfTheShortSide() {
        let corner = ScreenCornerPolicy.corner(
            deviceRadius: 900,
            displaySize: CGSize(width: 1080, height: 2424),
            declaredRadius: nil,
            openingRadius: nil,
            hasTransparentOpening: false
        )
        XCTAssertEqual(corner.radius, 540)
    }
}
