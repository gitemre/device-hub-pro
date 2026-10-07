import AppKit
import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// Renders every installed SDK skin's catalog preview (card and detail size)
/// next to a reference composited straight from the skin files, into the
/// folder named by `DHP_SKIN_AUDIT_DIR` (skipped without it). A review
/// aid, not an assertion: the regression assertions are in
/// `SkinThumbnailGeometryTests`.
final class SkinCatalogAuditTests: XCTestCase {
    func testRenderEveryInstalledSkin() throws {
        guard let out = ProcessInfo.processInfo.environment["DHP_SKIN_AUDIT_DIR"] else {
            throw XCTSkip("DHP_SKIN_AUDIT_DIR not set")
        }
        let skins = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Android/sdk/skins")
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        let scale = CGFloat(Double(ProcessInfo.processInfo.environment["DHP_SKIN_AUDIT_SCALE"] ?? "") ?? 2)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cards: [(String, CGImage)] = []
        var refCards: [(String, CGImage)] = []
        var summary = "name,size,meanDiff,pixelsOver64,holesInScreen\n"
        defer {
            for (title, list) in [("app", cards), ("ref", refCards)] {
                for (n, chunk) in stride(from: 0, to: list.count, by: 24).map({ Array(list[$0..<min($0 + 24, list.count)]) }).enumerated() {
                    if let sheet = Self.contactSheet(chunk), let rep = Optional(NSBitmapImageRep(cgImage: sheet)) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("sheet_\(title)_\(n).png"))
                    }
                }
            }
        }
        defer { try? summary.write(to: dir.appendingPathComponent("summary.csv"), atomically: true, encoding: .utf8) }
        for entry in SkinResolver.catalog(skinsDirectory: skins) {
            for variant in entry.variants {
                for (label, height) in [("card", CGFloat(230)), ("detail", CGFloat(520))] {
                    let name = "\(entry.category.rawValue)__\(entry.name)__\(variant.id)__\(label)"
                    if let image = SkinThumbnail.render(variant: variant, height: height, scale: scale) {
                        try Self.write(image, to: dir.appendingPathComponent(name + "__app.png"))
                        if let ref = Self.reference(variant: variant, pixelHeight: Int((height * scale).rounded(.up))) {
                            try Self.write(ref, to: dir.appendingPathComponent(name + "__ref.png"))
                            if label == "card" { cards.append((entry.name + (variant.id == "default" ? "" : "/" + variant.id), image)); refCards.append((entry.name, ref)) }
                            if label == "card", let corners = Self.corners(of: image) {
                                try Self.write(corners, to: dir.appendingPathComponent(name + "__corners.png"))
                            }
                            summary += "\(name),\(Self.diff(image, ref)),\(Self.enclosedHoles(in: image, variant: variant))\n"
                        }
                    }
                }
            }
        }
    }

    /// "WxH,mean,count" of the per-channel difference of two images (the
    /// second drawn at the first's size when they differ by a pixel or two).
    static func diff(_ a: CGImage, _ b: CGImage) -> String {
        let w = a.width, h = a.height
        func bytes(_ i: CGImage) -> [UInt8] {
            var d = [UInt8](repeating: 0, count: w * h * 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            d.withUnsafeMutableBytes { p in
                let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.interpolationQuality = .none
                c.draw(i, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return d
        }
        let x = bytes(a), y = bytes(b)
        var sum = 0, over = 0
        for p in 0..<(w * h) {
            var m = 0
            for c in 0..<3 { let d = abs(Int(x[p * 4 + c]) - Int(y[p * 4 + c])); sum += d; m = max(m, d) }
            if m > 64 { over += 1 }
        }
        return "\(w)x\(h)/\(b.width)x\(b.height),\(String(format: "%.2f", Double(sum) / Double(w * h * 3))),\(over)"
    }

    /// The four corners of `image` (a 36 px square each) enlarged 6x without
    /// smoothing, side by side: leaks of artwork at the screen corners show.
    static func corners(of image: CGImage) -> CGImage? {
        let n = min(36, image.width / 2, image.height / 2)
        guard n > 4, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: n * 6 * 4 + 16, height: n * 6, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.interpolationQuality = .none
        let origins = [(0, 0), (image.width - n, 0), (0, image.height - n), (image.width - n, image.height - n)]
        for (i, o) in origins.enumerated() {
            guard let crop = image.cropping(to: CGRect(x: o.0, y: o.1, width: n, height: n)) else { continue }
            ctx.draw(crop, in: CGRect(x: i * (n * 6 + 4), y: 0, width: n * 6, height: n * 6))
        }
        return ctx.makeImage()
    }

    /// Count of see-through pixels (alpha under 250) inside the display rect
    /// of a rendered preview that are not connected to the image's border
    /// through see-through pixels: enclosed holes, the wedges where the
    /// placeholder does not cover the artwork's opening. (The clear space
    /// outside a phone's silhouette, which can reach into a thin-bezel
    /// phone's display rect at its corners, is connected to the border.)
    static func enclosedHoles(in image: CGImage, variant: SkinVariant) -> Int {
        guard let d = variant.layout?.preferred else { return 0 }
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { p in
            let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.interpolationQuality = .none
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func clear(_ i: Int) -> Bool { data[i * 4 + 3] < 250 }
        for x in 0..<w { for y in [0, h - 1] where clear(y * w + x) && !outside[y * w + x] { outside[y * w + x] = true; stack.append(y * w + x) } }
        for y in 0..<h { for x in [0, w - 1] where clear(y * w + x) && !outside[y * w + x] { outside[y * w + x] = true; stack.append(y * w + x) } }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                let j = ny * w + nx
                if !outside[j], clear(j) { outside[j] = true; stack.append(j) }
            }
        }
        let ppu = CGFloat(h) / d.layoutSize.height
        let r = d.screenRect
        var n = 0
        for y in Int((r.minY * ppu).rounded(.up))..<min(Int((r.maxY * ppu).rounded(.down)), h) {
            for x in Int((r.minX * ppu).rounded(.up))..<min(Int((r.maxX * ppu).rounded(.down)), w) where clear(y * w + x) && !outside[y * w + x] { n += 1 }
        }
        return n
    }

    /// Every Apple device type Xcode ships, drawn in its DeviceKit chrome as
    /// the catalog draws it (`SkinThumbnail.renderVector`), into `apple_*`.
    func testRenderEveryAppleDeviceType() throws {
        guard let out = ProcessInfo.processInfo.environment["DHP_SKIN_AUDIT_DIR"] else {
            throw XCTSkip("DHP_SKIN_AUDIT_DIR not set")
        }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes", isDirectory: true)
        let bundles = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix(".simdevicetype") }.sorted()
        guard !bundles.isEmpty else { throw XCTSkip("no device types installed") }
        let provider = AppleChromeFrameProvider()
        var cards: [(String, CGImage)] = []
        var missing: [String] = []
        for name in bundles {
            let bundle = root.appendingPathComponent(name, isDirectory: true)
            guard let profile = SimulatorDisplayProfile.read(deviceTypeBundle: bundle),
                  let frame = provider.frame(deviceTypeBundle: bundle, display: profile) else { missing.append(name); continue }
            let plan = DeviceCompositionPlanner.appleChrome(frame)
            for (label, height) in [("card", CGFloat(230)), ("detail", CGFloat(520))] {
                if let image = SkinThumbnail.renderVector(plan, height: height, scale: 2) {
                    let base = name.replacingOccurrences(of: ".simdevicetype", with: "")
                    try Self.write(image, to: dir.appendingPathComponent("apple__\(base)__\(label).png"))
                    if label == "card" { cards.append((base, image)) }
                }
            }
        }
        try missing.joined(separator: "\n").write(to: dir.appendingPathComponent("apple_without_chrome.txt"), atomically: true, encoding: .utf8)
        for (n, chunk) in stride(from: 0, to: cards.count, by: 24).map({ Array(cards[$0..<min($0 + 24, cards.count)]) }).enumerated() {
            if let sheet = Self.contactSheet(chunk) { try Self.write(sheet, to: dir.appendingPathComponent("sheet_apple_\(n).png")) }
        }
    }

    /// A grid of previews, six to a row, each at most 230 px tall, titled.
    static func contactSheet(_ items: [(String, CGImage)]) -> CGImage? {
        let columns = 6, cellW = 300, cellH = 270
        let rows = (items.count + columns - 1) / columns
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: columns * cellW, height: rows * cellH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, item) in items.enumerated() {
            let col = i % columns, row = i / columns
            let x = col * cellW, y = (rows - 1 - row) * cellH
            let k = min(CGFloat(cellW - 20) / CGFloat(item.1.width), 230 / CGFloat(item.1.height))
            let w = CGFloat(item.1.width) * k, h = CGFloat(item.1.height) * k
            ctx.draw(item.1, in: CGRect(x: CGFloat(x) + (CGFloat(cellW) - w) / 2, y: CGFloat(y) + 30, width: w, height: h))
            (item.0 as NSString).draw(at: NSPoint(x: x + 8, y: y + 8), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// back image at the layout's artwork origin, a blue rect on the display
    /// rect, the mask over it at the display rect; downscaled once, high quality.
    static func reference(variant: SkinVariant, pixelHeight: Int) -> CGImage? {
        guard let d = variant.layout?.preferred else { return nil }
        let w = Int(d.layoutSize.width), h = Int(d.layoutSize.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func load(_ n: String?) -> CGImage? { SkinThumbnail.decode(named: n, in: variant.directory, maxPixelSize: 8000) }
        if let back = load(d.backgroundImage) {
            let r = d.artworkRect(pixelSize: CGSize(width: back.width, height: back.height))
            ctx.draw(back, in: CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height))
        }
        let s = d.screenRect
        let screen = CGRect(x: s.minX, y: CGFloat(h) - s.maxY, width: s.width, height: s.height)
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [CGColor(srgbRed: 0.333, green: 0.663, blue: 0.914, alpha: 1),
                     CGColor(srgbRed: 0.227, green: 0.561, blue: 0.812, alpha: 1)] as CFArray,
            locations: [0, 1]
        ) {
            ctx.saveGState()
            ctx.clip(to: screen)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: screen.minY), end: CGPoint(x: 0, y: screen.maxY), options: [])
            ctx.restoreGState()
        }
        if let mask = load(d.maskImage) {
            ctx.draw(mask, in: CGRect(x: s.minX, y: CGFloat(h) - s.maxY, width: s.width, height: s.height))
        }
        guard let full = ctx.makeImage() else { return nil }
        let ow = max(Int((Double(w) * Double(pixelHeight) / Double(h)).rounded()), 1)
        guard let out = CGContext(data: nil, width: ow, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        out.interpolationQuality = .high
        out.draw(full, in: CGRect(x: 0, y: 0, width: ow, height: pixelHeight))
        return out.makeImage()
    }
}
