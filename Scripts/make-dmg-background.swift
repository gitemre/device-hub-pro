#!/usr/bin/env swift
// Draws the disk image window's background and writes
// packaging/dmg/background.tiff (1x and 2x in one file, as Finder wants).
//
//   swift Scripts/make-dmg-background.swift
//
// The window is 660 x 400 pt. Scripts/dmg-settings.py places the app at
// (170, 190) and the Applications link at (490, 190), 128 pt icons, so the
// arrow and the caption here sit between and under those two. The look
// follows the app icon: a white-to-grey field with faint rings. It uses no
// Apple, Google or Android marks. Run from the repository root.

import AppKit
import Foundation

let width: CGFloat = 660
let height: CGFloat = 400
/// Icon centres from the window's top-left (Finder's coordinates); keep in
/// sync with Scripts/dmg-settings.py.
let appCentre = CGPoint(x: 170, y: 190)
let linkCentre = CGPoint(x: 490, y: 190)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Converts a top-left point to the bottom-left drawing space.
func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: height - point.y) }

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Field.
    NSGradient(colors: [color(0xFFFFFF), color(0xE9EDF3)])!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // The hub's rings, centred between the two icons.
    let hub = flip(CGPoint(x: (appCentre.x + linkCentre.x) / 2, y: appCentre.y))
    ctx.setStrokeColor(color(0x9CC2F0, alpha: 0.45).cgColor)
    ctx.setLineWidth(1.5)
    for radius in stride(from: CGFloat(70), through: 420, by: 58) {
        ctx.strokeEllipse(in: CGRect(x: hub.x - radius, y: hub.y - radius, width: 2 * radius, height: 2 * radius))
    }

    // Arrow from the app towards Applications.
    let start = flip(CGPoint(x: appCentre.x + 92, y: appCentre.y))
    let end = flip(CGPoint(x: linkCentre.x - 92, y: linkCentre.y))
    let arrow = color(0x1F5FFF, alpha: 0.85).cgColor
    ctx.setStrokeColor(arrow)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [0.1, 13])
    ctx.move(to: start)
    ctx.addLine(to: CGPoint(x: end.x - 14, y: end.y))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setLineWidth(5)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: end.x - 16, y: end.y + 14))
    ctx.addLine(to: end)
    ctx.addLine(to: CGPoint(x: end.x - 16, y: end.y - 14))
    ctx.strokePath()

    // Caption under the icons' labels.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let caption = NSAttributedString(
        string: "Drag Device Hub Pro to Applications to install it",
        attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: color(0x4D5873),
            .paragraphStyle: paragraph,
        ]
    )
    caption.draw(in: NSRect(x: 0, y: height - 345, width: width, height: 22))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outputDirectory = URL(fileURLWithPath: "packaging/dmg", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("dhp-dmg-bg-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

var parts: [String] = []
for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    let url = work.appendingPathComponent(name)
    try draw(scale: scale).representation(using: .png, properties: [:])!.write(to: url)
    parts.append(url.path)
}
let output = outputDirectory.appendingPathComponent("background.tiff")
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck"] + parts + ["-out", output.path]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("make-dmg-background: tiffutil failed\n".utf8))
    exit(1)
}
print("wrote \(output.path)")
