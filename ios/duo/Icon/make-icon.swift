// Draws Daybreak's app icon: a sun half risen between dark hills over a
// still lake, in a dawn sky (indigo to rose to gold), with a faint vertical
// fold through the middle for iPhone Duo. Everything is drawn here with
// CoreGraphics, so the icon has no source art to keep in step. It is full
// bleed and opaque: iOS masks the corners, and the App Store refuses alpha.
//
//   swift ios/duo/Icon/make-icon.swift ios/duo/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// Run it on a Mac after changing the drawing, and commit the PNG it writes:
// build.sh compiles the asset catalog, never this script.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <out.png>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

let side: CGFloat = 1024
let middle = side / 2
/// The waterline, a little below the centre so the sky gets the room.
let horizon: CGFloat = 600
let sunRadius: CGFloat = 200
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// Runs `draw` clipped to `rect`, leaving the clip as it was.
func clipped(_ context: CGContext, to rect: CGRect, _ draw: () -> Void) {
    context.saveGState()
    context.clip(to: rect)
    draw()
    context.restoreGState()
}

// No alpha channel: noneSkipLast makes ImageIO write a plain RGB PNG.
guard let context = CGContext(
    data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write(Data("make-icon: no bitmap context\n".utf8))
    exit(1)
}
// Top-left origin, y down, like the app's own drawing.
context.translateBy(x: 0, y: side)
context.scaleBy(x: 1, y: -1)
context.interpolationQuality = .high
context.setShouldAntialias(true)

let sky = CGRect(x: 0, y: 0, width: side, height: horizon)
let lake = CGRect(x: 0, y: horizon, width: side, height: side - horizon)
let sunCentre = CGPoint(x: middle, y: horizon)

// Sky: night still at the top, dawn at the waterline.
context.drawLinearGradient(
    gradient([
        (0.00, color(0x12153E)),
        (0.28, color(0x2A2A6C)),
        (0.52, color(0x5E3C88)),
        (0.72, color(0xB45A8A)),
        (0.87, color(0xEE8478)),
        (1.00, color(0xFFC57A)),
    ]),
    start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: horizon),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

clipped(context, to: sky) {
    // The warm wash the sun throws on the low sky.
    context.drawRadialGradient(
        gradient([
            (0.00, color(0xFFDDA0, 0.80)),
            (0.30, color(0xFFB27C, 0.42)),
            (0.65, color(0xF07C86, 0.12)),
            (1.00, color(0xF07C86, 0)),
        ]),
        startCenter: sunCentre, startRadius: 0,
        endCenter: sunCentre, endRadius: 620,
        options: []
    )

    // The last stars, fading as the sky warms below them.
    let stars: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
        (148, 112, 4.2), (262, 206, 2.6), (356, 78, 3.0), (452, 168, 2.2),
        (628, 96, 2.6), (742, 190, 3.4), (858, 92, 2.4), (930, 236, 2.8),
        (96, 268, 2.2), (568, 238, 1.9), (812, 300, 1.8), (204, 352, 1.7),
    ]
    for star in stars {
        let fade = max(0, 1 - star.y / (horizon * 0.66))
        let halo = star.r * 4
        context.drawRadialGradient(
            gradient([(0, color(0xFFFFFF, 0.30 * fade)), (1, color(0xFFFFFF, 0))]),
            startCenter: CGPoint(x: star.x, y: star.y), startRadius: 0,
            endCenter: CGPoint(x: star.x, y: star.y), endRadius: halo, options: []
        )
        context.setFillColor(color(0xFFFFFF, 0.92 * fade))
        context.fillEllipse(in: CGRect(x: star.x - star.r, y: star.y - star.r, width: star.r * 2, height: star.r * 2))
    }

    // Corona, then the disc: pale at the crown, deep gold at the waterline.
    context.drawRadialGradient(
        gradient([(0, color(0xFFE2A8, 0.55)), (1, color(0xFFC88A, 0))]),
        startCenter: sunCentre, startRadius: sunRadius,
        endCenter: sunCentre, endRadius: sunRadius * 1.55,
        options: []
    )
    context.saveGState()
    context.addEllipse(in: CGRect(
        x: sunCentre.x - sunRadius, y: sunCentre.y - sunRadius,
        width: sunRadius * 2, height: sunRadius * 2
    ))
    context.clip()
    context.drawLinearGradient(
        gradient([
            (0.00, color(0xFFF7DE)),
            (0.45, color(0xFFE39C)),
            (1.00, color(0xFFAE52)),
        ]),
        start: CGPoint(x: 0, y: horizon - sunRadius), end: CGPoint(x: 0, y: horizon),
        options: []
    )
    context.restoreGState()
}

/// A closed silhouette standing on the waterline: `segments` are cubic
/// segments (two controls and an end) after a start on the edge.
func hill(from start: CGPoint, _ segments: [(CGPoint, CGPoint, CGPoint)], fill: CGGradient) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: start.x, y: horizon))
    path.addLine(to: start)
    for (c1, c2, end) in segments {
        path.addCurve(to: end, control1: c1, control2: c2)
    }
    path.closeSubpath()
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        fill, start: CGPoint(x: 0, y: horizon - 220), end: CGPoint(x: 0, y: horizon), options: [.drawsAfterEndLocation]
    )
    context.restoreGState()
}

func p(_ x: CGFloat, _ rise: CGFloat) -> CGPoint { CGPoint(x: x, y: horizon - rise) }

/// The hills either side of the valley the sun rises in: far ridges hazed
/// by the dawn, near ones almost night.
func hills() {
    let far = gradient([(0, color(0x5A3A72)), (1, color(0x7A4A78))])
    hill(from: p(0, 176), [
        (p(80, 206), p(160, 150), p(236, 118)),
        (p(300, 92), p(352, 40), p(430, 0)),
    ], fill: far)
    hill(from: p(side, 140), [
        (p(944, 182), p(866, 122), p(790, 92)),
        (p(716, 64), p(668, 24), p(600, 0)),
    ], fill: far)
    let near = gradient([(0, color(0x2A2050)), (1, color(0x1C1638))])
    hill(from: p(0, 92), [
        (p(96, 112), p(214, 60), p(330, 0)),
    ], fill: near)
    hill(from: p(side, 104), [
        (p(912, 124), p(800, 56), p(694, 0)),
    ], fill: near)
}
hills()

clipped(context, to: lake) {
    // Still water, dark, with the glow of the sun laid on it flat.
    context.drawLinearGradient(
        gradient([(0, color(0x2B2050)), (0.45, color(0x17143A)), (1, color(0x0B0B22))]),
        start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: side),
        options: []
    )
    context.saveGState()
    context.translateBy(x: middle, y: horizon)
    context.scaleBy(x: 1, y: 0.30)
    context.drawRadialGradient(
        gradient([(0, color(0xFFB27C, 0.55)), (0.5, color(0xE07088, 0.18)), (1, color(0xE07088, 0))]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 560, options: []
    )
    context.restoreGState()

    // The hills again, upside down and dimmed as one layer: the lake is still.
    context.saveGState()
    context.translateBy(x: 0, y: horizon * 2)
    context.scaleBy(x: 1, y: -1)
    context.setAlpha(0.34)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    hills()
    context.endTransparencyLayer()
    context.restoreGState()

    // The sun's reflection, broken into ripples that narrow with depth.
    let ripples: [(depth: CGFloat, half: CGFloat, height: CGFloat, alpha: CGFloat)] = [
        (26, 176, 13, 0.95), (60, 142, 11, 0.78), (96, 106, 10, 0.60),
        (134, 74, 9, 0.44), (176, 46, 8, 0.32), (222, 24, 7, 0.22),
    ]
    for ripple in ripples {
        let rect = CGRect(
            x: middle - ripple.half, y: horizon + ripple.depth - ripple.height / 2,
            width: ripple.half * 2, height: ripple.height
        )
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: ripple.height / 2, cornerHeight: ripple.height / 2, transform: nil))
        context.clip()
        context.drawLinearGradient(
            gradient([
                (0.0, color(0xFFC77E, ripple.alpha * 0.35)),
                (0.5, color(0xFFE2A6, ripple.alpha)),
                (1.0, color(0xFFC77E, ripple.alpha * 0.35)),
            ]),
            start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: []
        )
        context.restoreGState()
    }
}

// The waterline catches the light where the sun meets it.
context.saveGState()
context.clip(to: CGRect(x: 0, y: horizon - 1.5, width: side, height: 3))
context.drawLinearGradient(
    gradient([
        (0.0, color(0xFFE2B0, 0)),
        (0.5, color(0xFFE9C2, 0.85)),
        (1.0, color(0xFFE2B0, 0)),
    ]),
    start: CGPoint(x: middle - 380, y: 0), end: CGPoint(x: middle + 380, y: 0),
    options: []
)
context.restoreGState()

// The fold: a soft shade into the hinge on one page, a sheen off it on the
// other, and a hairline at the hinge itself. Faint, so the sun stays whole.
context.saveGState()
context.clip(to: CGRect(x: middle - 40, y: 0, width: 40, height: side))
context.drawLinearGradient(
    gradient([(0, color(0x000000, 0)), (1, color(0x000000, 0.12))]),
    start: CGPoint(x: middle - 40, y: 0), end: CGPoint(x: middle, y: 0), options: []
)
context.restoreGState()
context.saveGState()
context.clip(to: CGRect(x: middle, y: 0, width: 32, height: side))
context.drawLinearGradient(
    gradient([(0, color(0xFFFFFF, 0.08)), (1, color(0xFFFFFF, 0))]),
    start: CGPoint(x: middle, y: 0), end: CGPoint(x: middle + 32, y: 0), options: []
)
context.restoreGState()
context.setFillColor(color(0x000000, 0.18))
context.fill(CGRect(x: middle - 1, y: 0, width: 2, height: side))

guard
    let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("make-icon: cannot write \(output.path)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("make-icon: cannot write \(output.path)\n".utf8))
    exit(1)
}
print("Wrote \(output.path)")
