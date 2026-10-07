import CoreGraphics
import Foundation

/// Android's display-cutout spec (`config_mainBuiltInDisplayCutout`, the
/// `cutoutSpec={…}` in `dumpsys display`) resolved to a path in display
/// pixels, as `android.view.CutoutSpecification.Parser` resolves it.
///
/// `dumpsys` prints the spec raw, markers included: SVG path data (read by
/// `AndroidPathParser`) positioned by `@left`/`@right` (x origin at that
/// edge; the horizontal centre otherwise), `@bottom`/`@center_vertical`
/// (y origin; the top otherwise), and scaled from dp by one `@dp` anywhere
/// in the spec. `@bottom`, `@center_vertical` and `@cutout` end one cutout
/// and start the next; `@bind_left_cutout`/`@bind_right_cutout` claim a
/// cutout for that edge (`@bottom` claims the bottom one, anything else the
/// top). As on Android, only the first cutout claiming each edge is kept,
/// a piece shorter than `H1V1Z` or with an empty rounded bounding box is
/// skipped, and a piece whose path data does not parse fails the whole spec.
///
/// Ported from AOSP `frameworks/base/core/java/android/view/`
/// `CutoutSpecification.java` (the parser) and `DisplayCutout.java`
/// (`getCutoutPath`). Unknown `@` markers are dropped one character at a
/// time as there: `@foo` leaves `foo` in the path data, which then fails.
public enum CutoutSpecification {
    /// The display edge a cutout is bound to (`Parser.setEdgeCutout`).
    enum Edge: Equatable {
        case top, left, right, bottom
    }

    /// One resolved cutout: the edge it claimed and its path in display
    /// pixels (before `physicalPixelDisplaySizeRatio`).
    struct Piece {
        let edge: Edge
        let path: CGPath
    }

    /// The cutout outline of `spec` in display pixels (the natural
    /// orientation, top-left origin), or nil when there is none or the spec
    /// does not parse.
    ///
    /// - Parameters:
    ///   - density: dp → px factor for `@dp` (`density={…}` in the dump,
    ///     the display's dpi / 160).
    ///   - physicalWidth: the full panel's width in pixels, where the
    ///     `@right` and centre origins sit (`physicalDisplayWidth=`).
    ///   - physicalHeight: the full panel's height (`physicalDisplayHeight=`).
    ///   - physicalPixelDisplaySizeRatio: the display mode's size over the
    ///     full panel's (below 1 in a Pixel's reduced-resolution mode): the
    ///     spec is written for the full panel and scaled down to the mode.
    public static func path(
        spec: String,
        density: CGFloat,
        physicalWidth: Int,
        physicalHeight: Int,
        physicalPixelDisplaySizeRatio: CGFloat = 1
    ) -> CGPath? {
        guard let pieces = pieces(
            spec: spec,
            density: density,
            width: physicalWidth,
            height: physicalHeight
        ), !pieces.isEmpty
        else { return nil }
        let union = CGMutablePath()
        for piece in pieces {
            union.addPath(piece.path)
        }
        guard !union.isEmpty else { return nil }
        guard physicalPixelDisplaySizeRatio != 1 else { return union }
        var scale = CGAffineTransform(
            scaleX: physicalPixelDisplaySizeRatio,
            y: physicalPixelDisplaySizeRatio
        )
        return union.copy(using: &scale)
    }

    /// `Parser.parse`: the kept cutouts in spec order, or nil when a piece's
    /// path data fails (Android throws there).
    static func pieces(spec: String, density: CGFloat, width: Int, height: Int) -> [Piece]? {
        var parser = Parser(density: density, width: width, height: height)
        var text = spec
        if let dp = text.range(of: "@dp", options: .backwards) {
            parser.inDp = true
            text.removeSubrange(dp)
        }
        guard parser.parse(Array(text.utf8)) else { return nil }
        return parser.pieces
    }

    // MARK: - Parser

    private struct Parser {
        let density: CGFloat
        let width: Int
        let height: Int
        var inDp = false

        var positionFromLeft = false
        var positionFromRight = false
        var positionFromBottom = false
        var positionFromCenterVertical = false
        var bindLeft = false
        var bindRight = false
        var bindBottom = false

        var pieces: [Piece] = []
        var claimed: [Edge] = []

        init(density: CGFloat, width: Int, height: Int) {
            self.density = density
            self.width = width
            self.height = height
        }

        /// `parseSpecWithoutDp`. False when a piece fails to parse.
        mutating func parse(_ spec: [UInt8]) -> Bool {
            let at = UInt8(ascii: "@")
            var piece: [UInt8]?
            var lastIndex = 0
            while let markerIndex = spec[lastIndex...].firstIndex(of: at) {
                var current = markerIndex
                piece = (piece ?? []) + spec[lastIndex..<current]

                if Self.marker("@left", in: spec, at: current) {
                    if !positionFromRight { positionFromLeft = true }
                    current += "@left".utf8.count
                } else if Self.marker("@right", in: spec, at: current) {
                    if !positionFromLeft { positionFromRight = true }
                    current += "@right".utf8.count
                } else if Self.marker("@bottom", in: spec, at: current) {
                    guard flush(piece ?? []) else { return false }
                    current += "@bottom".utf8.count
                    reset(&piece)
                    bindBottom = true
                    positionFromBottom = true
                } else if Self.marker("@center_vertical", in: spec, at: current) {
                    guard flush(piece ?? []) else { return false }
                    current += "@center_vertical".utf8.count
                    reset(&piece)
                    positionFromCenterVertical = true
                } else if Self.marker("@cutout", in: spec, at: current) {
                    guard flush(piece ?? []) else { return false }
                    current += "@cutout".utf8.count
                    reset(&piece)
                } else if Self.marker("@bind_left_cutout", in: spec, at: current) {
                    bindBottom = false
                    bindRight = false
                    bindLeft = true
                    current += "@bind_left_cutout".utf8.count
                } else if Self.marker("@bind_right_cutout", in: spec, at: current) {
                    bindBottom = false
                    bindLeft = false
                    bindRight = true
                    current += "@bind_right_cutout".utf8.count
                } else {
                    current += 1
                }
                lastIndex = current
            }
            guard let piece else { return flush(spec) }
            return flush(piece + spec[lastIndex...])
        }

        private static func marker(_ marker: String, in spec: [UInt8], at index: Int) -> Bool {
            spec[index...].starts(with: marker.utf8)
        }

        /// `resetStatus`: a new cutout starts with no position or binding.
        private mutating func reset(_ piece: inout [UInt8]?) {
            piece = []
            positionFromBottom = false
            positionFromLeft = false
            positionFromRight = false
            positionFromCenterVertical = false
            bindLeft = false
            bindRight = false
            bindBottom = false
        }

        /// `parseSvgPathSpec` + `setEdgeCutout`: resolves one cutout and
        /// keeps it when its edge is still free. False when it fails.
        private mutating func flush(_ piece: [UInt8]) -> Bool {
            // MINIMAL_ACCEPTABLE_PATH_LENGTH ("H1V1Z"); the spec is ASCII.
            guard piece.count >= 5 else { return true }
            guard let text = String(bytes: piece, encoding: .utf8),
                  let parsed = AndroidPathParser.path(text)
            else { return false }

            let offsetX: CGFloat = positionFromRight
                ? CGFloat(width)
                : positionFromLeft ? 0 : CGFloat(width) / 2
            let offsetY: CGFloat = positionFromBottom
                ? CGFloat(height)
                : positionFromCenterVertical ? CGFloat(height) / 2 : 0
            let scale = inDp ? density : 1
            var transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
            guard let path = parsed.copy(using: &transform) else { return false }

            // Android skips a cutout whose bounds (control points included,
            // as Skia's getBounds) round to an empty rect.
            let bounds = path.boundingBox
            guard !bounds.isNull,
                  Self.round(bounds.minX) < Self.round(bounds.maxX),
                  Self.round(bounds.minY) < Self.round(bounds.maxY)
            else { return true }

            let edge: Edge
            if bindRight, !claimed.contains(.right) {
                edge = .right
            } else if bindLeft, !claimed.contains(.left) {
                edge = .left
            } else if bindBottom, !claimed.contains(.bottom) {
                edge = .bottom
            } else if !(bindBottom || bindLeft || bindRight), !claimed.contains(.top) {
                edge = .top
            } else {
                return true
            }
            claimed.append(edge)
            pieces.append(Piece(edge: edge, path: path))
            return true
        }

        /// Java's `Math.round(float)`.
        private static func round(_ value: CGFloat) -> CGFloat {
            (value + 0.5).rounded(.down)
        }
    }
}
