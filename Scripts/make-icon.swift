#!/usr/bin/env swift
// Draws Device Hub Pro's app icon with Core Graphics and builds
// packaging/AppIcon.icns with iconutil.
//
//   swift Scripts/make-icon.swift            # writes packaging/AppIcon.icns
//   swift Scripts/make-icon.swift --png out.png   # also keeps the 1024 px master
//
// The artwork is original: a white squircle on the macOS icon grid (an 824 pt
// body on the 1024 pt canvas) with faint rings spreading from the middle (the
// hub), and three liquid-glass devices over them: a violet tablet behind, a
// blue phone with a pill-shaped camera and a green phone with a punch-hole
// camera, for iOS and Android. It uses no Apple, Google or Android marks.
// Run from the repository root.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// The macOS icon grid: 1024 pt canvas, 824 pt body inset by 100 pt, the
/// body's shadow falling toward the bottom edge.
let canvas: CGFloat = 1024
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)

/// A superellipse ("squircle") through `rect`, close to the continuous-corner
/// rounded rectangle of macOS app icons.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5.0, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    for index in 0...steps {
        let t = CGFloat(index) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t)
        let sinT = sin(t)
        let x = center.x + a * copysign(pow(abs(cosT), 2 / exponent), cosT)
        let y = center.y + b * copysign(pow(abs(sinT), 2 / exponent), sinT)
        if index == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func linearGradient(_ colors: [CGColor], locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: colors as CFArray,
        locations: locations
    )!
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillLinear(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    context.drawLinearGradient(
        linearGradient(colors),
        start: start,
        end: end,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

// MARK: - Drawing

/// One liquid-glass slab: a translucent diagonal gradient, a soft shadow in its
/// own colour, a sheen from the top and a bright rim fading downward.
func drawGlass(in context: CGContext, _ path: CGPath, top: UInt32, bottom: UInt32, alpha: CGFloat, detailed: Bool) {
    let box = path.boundingBox
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -16), blur: 46, color: color(bottom, alpha: 0.45))
    context.addPath(path)
    context.setFillColor(color(bottom, alpha: alpha * 0.6))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    fillLinear(context, [color(top, alpha: alpha), color(bottom, alpha: alpha)],
               from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.maxX, y: box.minY))
    fillLinear(context, [color(0xFFFFFF, alpha: 0.35), color(0xFFFFFF, alpha: 0)],
               from: CGPoint(x: box.midX, y: box.maxY), to: CGPoint(x: box.midX, y: box.maxY - box.height * 0.45))
    context.restoreGState()

    guard detailed else { return }
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.addPath(path)
    context.setLineWidth(10)
    context.replacePathWithStrokedPath()
    context.clip()
    fillLinear(context, [color(0xFFFFFF, alpha: 0.85), color(0xFFFFFF, alpha: 0.15)],
               from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.maxX, y: box.minY))
    context.restoreGState()
}

/// Draws the icon on the 1024 pt grid; `pixels` is the output size, used to
/// drop details that would only be noise at 16 and 32 px.
func drawIcon(in context: CGContext, pixels: Int) {
    let detailed = pixels >= 64
    let body = squirclePath(in: bodyRect)

    // Body shadow (Apple's template: a soft shadow below the body).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, alpha: 0.28))
    context.addPath(body)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    // Body: white to a cool grey, with the hub's rings.
    context.saveGState()
    context.addPath(body)
    context.clip()
    fillLinear(context, [color(0xFFFFFF), color(0xE9EDF3)],
               from: CGPoint(x: 512, y: bodyRect.maxY), to: CGPoint(x: 512, y: bodyRect.minY))
    if detailed {
        context.setStrokeColor(color(0x9CC2F0, alpha: 0.55))
        context.setLineWidth(5)
        for radius in stride(from: CGFloat(150), through: 700, by: 110) {
            context.strokeEllipse(in: CGRect(x: 512 - radius, y: 470 - radius, width: 2 * radius, height: 2 * radius))
        }
    }
    context.restoreGState()
    context.addPath(squirclePath(in: bodyRect.insetBy(dx: 1.5, dy: 1.5)))
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.9))
    context.setLineWidth(3)
    context.strokePath()

    // Tablet (violet), behind.
    drawGlass(in: context, roundedRect(CGRect(x: 250, y: 360, width: 520, height: 380), radius: 44),
              top: 0xC3B4FF, bottom: 0x8A6CF0, alpha: 0.62, detailed: detailed)

    // Phone with a pill-shaped camera (blue), left.
    let pillPhone = CGRect(x: 190, y: 190, width: 250, height: 470)
    drawGlass(in: context, roundedRect(pillPhone, radius: 62),
              top: 0x6FB8FF, bottom: 0x1F5FFF, alpha: 0.80, detailed: detailed)
    if detailed {
        context.addPath(roundedRect(CGRect(x: pillPhone.midX - 46, y: pillPhone.maxY - 57, width: 92, height: 26), radius: 13))
        context.setFillColor(color(0x0B1A3A, alpha: 0.55))
        context.fillPath()
    }

    // Phone with a punch-hole camera (green), right.
    let holePhone = CGRect(x: 560, y: 230, width: 270, height: 470)
    drawGlass(in: context, roundedRect(holePhone, radius: 48),
              top: 0x7FF0BF, bottom: 0x16B47A, alpha: 0.78, detailed: detailed)
    if detailed {
        context.setFillColor(color(0x063A26, alpha: 0.55))
        context.fillEllipse(in: CGRect(x: holePhone.midX - 13, y: holePhone.maxY - 57, width: 26, height: 26))
    }
}

func renderPNG(pixels: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError("could not create a \(pixels) px bitmap context")
    }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(in: context, pixels: pixels)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw IconError("could not encode \(url.lastPathComponent)")
    }
    // 72 dpi for 1x slots, 144 for @2x ones, as iconutil expects.
    let dpi = url.lastPathComponent.contains("@2x") ? 144 : 72
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError("could not write \(url.path)")
    }
}

struct IconError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Main

let arguments = CommandLine.arguments.dropFirst()
var masterPNG: URL?
var output = URL(fileURLWithPath: "packaging/AppIcon.icns")
var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--png":
        guard let path = iterator.next() else {
            FileHandle.standardError.write(Data("--png needs a path\n".utf8))
            exit(64)
        }
        masterPNG = URL(fileURLWithPath: path)
    case "--output":
        guard let path = iterator.next() else {
            FileHandle.standardError.write(Data("--output needs a path\n".utf8))
            exit(64)
        }
        output = URL(fileURLWithPath: path)
    case "-h", "--help":
        print("usage: swift Scripts/make-icon.swift [--output packaging/AppIcon.icns] [--png master.png]")
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
        exit(64)
    }
}

let fileManager = FileManager.default
let workDirectory = fileManager.temporaryDirectory
    .appendingPathComponent("devicehubpro-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = workDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
defer { try? fileManager.removeItem(at: workDirectory) }

do {
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    // Every slot iconutil knows: 16–512 pt at 1x and 2x.
    for points in [16, 32, 128, 256, 512] {
        try renderPNG(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try renderPNG(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
    if let masterPNG {
        try fileManager.createDirectory(at: masterPNG.deletingLastPathComponent(), withIntermediateDirectories: true)
        try renderPNG(pixels: 1024, to: masterPNG)
    }
    try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw IconError("iconutil failed with status \(iconutil.terminationStatus)")
    }
    print("wrote \(output.path)")
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
