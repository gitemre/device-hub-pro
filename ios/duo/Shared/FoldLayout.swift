import Foundation

// Where the fold runs through the window, from the division regions SwiftUI
// reports (`GeometryProxy.reservedRegions(kind: .division, options:
// .includeInactive)`). Measured on the iOS 27.1 Duo simulator: a 40 pt band
// centred on the hinge line, 455.5,0,40,669 in the 951 × 669 book and open
// windows, 0,455.5,669,40 in the 669 × 951 laptop window, none on the cover.

/// One reserved region, in the window's coordinates.
struct FoldRegion: Equatable, Sendable {
    var x, y, width, height: Double
    var isActive: Bool

    var isVertical: Bool { height > width }
}

/// How the one composition lies in the window. All values are in the
/// window's points.
enum SceneLayout: Equatable, Sendable {
    /// No usable fold (cover, a hinge-less iPhone): horizon at 0.64 of the height.
    case single(horizonY: Double)
    /// A vertical fold (book, open flat): spine centre x and half-width (margin), horizon at 0.64.
    case book(spineX: Double, halfWidth: Double, horizonY: Double)
    /// A horizontal fold (laptop): the horizon sits ON the crease; the lid (above) is sky, the base the lake.
    case lidAndBase(creaseY: Double, halfHeight: Double)
}

enum FoldLayout {
    /// The horizon's height as a fraction of the window's when the fold does
    /// not place it: low enough for a tall sky, high enough for the lake.
    private static let horizonFraction = 0.64
    /// How far a region may stick out of the window and still count, for
    /// frames rounded to half points.
    private static let tolerance = 0.5

    /// Picks the layout from the window size, its width class and the division
    /// regions. Ignores every region unless `regularWidth` and the region lies
    /// inside the bounds (±0.5 pt) and crosses the whole window, as the fold
    /// does: SwiftUI reports a stale region for a pass after the window moves
    /// or turns, sometimes active, such as 182.5,0,40,669 in the 678 × 466
    /// cover, or the book's 455.5,0,40,669 in the turned 669 × 951 window
    /// (inside the bounds, but 669 of 951 tall). When several are valid take
    /// the first. A valid region is used whether active or not: `isActive`
    /// turns false flat open and lags the posture by up to 2 s.
    static func layout(width: Double, height: Double, regularWidth: Bool, regions: [FoldRegion]) -> SceneLayout {
        let horizonY = height * horizonFraction
        guard regularWidth, let fold = regions.first(where: { fits($0, width: width, height: height) }) else {
            return .single(horizonY: horizonY)
        }
        if fold.isVertical {
            return .book(spineX: fold.x + fold.width / 2, halfWidth: fold.width / 2, horizonY: horizonY)
        }
        return .lidAndBase(creaseY: fold.y + fold.height / 2, halfHeight: fold.height / 2)
    }

    private static func fits(_ region: FoldRegion, width: Double, height: Double) -> Bool {
        guard region.x.isFinite, region.y.isFinite, region.width.isFinite, region.height.isFinite,
              region.width > 0, region.height > 0 else { return false }
        let inside = region.x >= -tolerance && region.y >= -tolerance
            && region.x + region.width <= width + tolerance
            && region.y + region.height <= height + tolerance
        let crosses = region.isVertical
            ? abs(region.height - height) <= tolerance
            : abs(region.width - width) <= tolerance
        return inside && crosses
    }
}
