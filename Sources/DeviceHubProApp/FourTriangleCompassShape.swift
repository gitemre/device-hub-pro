import SwiftUI

/// One outward-pointing triangle of ``FourTriangleCompassShape``.
private struct CompassTriangle: Shape {
    /// 0 = up, 1 = right, 2 = down, 3 = left (clockwise from north).
    let quadrant: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let half = min(rect.width, rect.height) / 2
        // Traced from a 2x crop of DH's icon (TB-06, 2026-09-28), in units of
        // the half-extent: the apex is at 1.0 on the axis, the base 0.5 from
        // the centre and 0.85 wide (±0.425), which leaves the gap at the middle
        // and the sharp corners DH's four triangles have.
        let apex = CGPoint(x: 0, y: -half)
        let baseY = -half * 0.5
        let baseHalf = half * 0.425
        let angle = CGFloat(quadrant) * (.pi / 2)
        func rotated(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: center.x + p.x * cos(angle) - p.y * sin(angle),
                y: center.y + p.x * sin(angle) + p.y * cos(angle)
            )
        }
        var path = Path()
        path.move(to: rotated(apex))
        path.addLine(to: rotated(CGPoint(x: baseHalf, y: baseY)))
        path.addLine(to: rotated(CGPoint(x: -baseHalf, y: baseY)))
        path.closeSubpath()
        return path
    }
}

/// Device Hub's "Zoom to Fit" inner glyph (TB-06): four small solid triangles
/// pointing up, right, down and left around a gap at the centre, drawn in
/// the magnifier's lens. DH's own name for the composite symbol
/// (`arrowtriangles.up.right.down.left.magnifyingglass`) is not in the public
/// SF Symbols catalog (`NSImage(systemSymbolName:)` returns nil for it on
/// this SDK) and the nearest public glyph, `dpad.fill`, draws four rounded
/// lobes, so the triangles are drawn here instead: no private asset or symbol
/// is used. Size the frame to the compass's full extent (7.5 pt matches DH's
/// 15 px at 2x).
struct FourTriangleCompassShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for quadrant in 0..<4 {
            path.addPath(CompassTriangle(quadrant: quadrant).path(in: rect))
        }
        return path
    }
}
