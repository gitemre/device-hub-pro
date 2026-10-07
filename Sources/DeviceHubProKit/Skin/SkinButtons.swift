import CoreGraphics
import Foundation
import ImageIO

/// One side button painted into a skin's frame artwork, found by
/// `SkinButtonScanner`.
public struct SkinHardwareButton: Sendable, Hashable {
    public var key: HardwareKey
    /// 0 = power, 1 = the volume rocker (its two halves hover together).
    public var group: Int
    /// Artwork px, top-left based: from the column after `baseline` through
    /// the bulge's outermost opaque column (`depth` wide), over the bulge's
    /// rows. The rocker is split at its midpoint row: the upper half is
    /// volume up.
    public var rect: CGRect
    /// The outermost opaque x of the body's straight right edge.
    public var baseline: Int
    /// How far the bulge sticks out past `baseline`, in artwork px.
    public var depth: Int

    public init(key: HardwareKey, group: Int, rect: CGRect, baseline: Int, depth: Int) {
        self.key = key
        self.group = group
        self.rect = rect
        self.baseline = baseline
        self.depth = depth
    }
}

/// Finds the power button and the volume rocker in a skin's frame artwork
/// from its transparency. SDK skins carry no button data (only `nexus_one`
/// and `nexus_s` have a `buttons` block), but every modern Pixel paints them
/// on the right edge: a shorter bulge on top (power) and a longer one below
/// (the rocker).
///
/// The rule: a row sticks out when its outermost opaque pixel (alpha ≥ 128)
/// lies at least 2 px past the baseline, the median outermost opaque x over
/// the middle 60 % of rows; a bulge is a run of at least 8 such rows that
/// reaches 4 px. Only exactly two bulges, each 4–12 px deep, the upper one
/// shorter, are accepted; anything else gives no buttons. On the installed
/// SDK this accepts every Pixel phone skin (both screens of the folds except
/// the 9 Pro Fold's flat cover) and the Nexus 5X, 6 and 6P, and rejects the
/// tablets, the Wear, TV and automotive skins and the older Nexus skins,
/// which paint power and volume on opposite sides or not at all
/// (`SkinButtonsTests` pins the list). The 9 Pro Fold's open frame paints
/// its buttons only 4 px deep, so 4 px (not 5) is the least depth a bulge
/// needs; the 2–3 px bumps of `nexus_s` and `pixel_c` stay below it.
public enum SkinButtonScanner {
    /// The alpha from which an artwork pixel counts as body.
    static let opaqueAlpha: UInt8 = 128
    /// How far past the baseline a row must reach to be part of a bulge; a
    /// 1 px threshold merges the anti-aliased wobble of older skins
    /// (`pixel_3a`, `pixel_7_pro`) into their bulges.
    static let rowProtrusion = 2
    /// The shortest bulge, in rows.
    static let minimumRows = 8
    /// How deep an accepted bulge is; shallower runs are not bulges at all.
    static let acceptedDepths = 4...12

    /// Scans an alpha plane (`width × height`, row-major, top row first).
    /// Returns power, volume up and volume down, or nothing.
    public static func scan(alpha: [UInt8], width: Int, height: Int) -> [SkinHardwareButton] {
        guard width > 0, height > 0, alpha.count == width * height else { return [] }
        let outermost = alpha.withUnsafeBufferPointer { pixels in
            outermostOpaqueColumns(width: width, height: height) { pixels[$0] }
        }
        return buttons(outermost: outermost)
    }

    /// Scans the artwork file (ImageIO decode); nothing when it does not
    /// decode.
    public static func scan(artworkURL: URL) -> [SkinHardwareButton] {
        guard let bitmap = SkinArtworkBitmap(url: artworkURL) else { return [] }
        let outermost = bitmap.pixels.withUnsafeBufferPointer { rgba in
            outermostOpaqueColumns(width: bitmap.width, height: bitmap.height) { rgba[$0 * 4 + 3] }
        }
        return buttons(outermost: outermost)
    }

    /// Each row's outermost opaque x, -1 for a row with none. `alpha` reads
    /// the alpha of pixel `y × width + x`. Walks in from the right, so it
    /// reads only the few transparent pixels beside the body.
    private static func outermostOpaqueColumns(
        width: Int,
        height: Int,
        alpha: (Int) -> UInt8
    ) -> [Int] {
        var outermost = [Int](repeating: -1, count: height)
        for y in 0..<height {
            let row = y * width
            var x = width - 1
            while x >= 0, alpha(row + x) < opaqueAlpha { x -= 1 }
            outermost[y] = x
        }
        return outermost
    }

    /// The scan rule over each row's outermost opaque x.
    private static func buttons(outermost: [Int]) -> [SkinHardwareButton] {
        let height = outermost.count
        let middle = (height / 5)..<(height - height / 5)
        let edges = middle.map { outermost[$0] }.filter { $0 >= 0 }.sorted()
        guard !edges.isEmpty else { return [] }
        let baseline = edges[edges.count / 2]

        var bulges: [(rows: ClosedRange<Int>, depth: Int)] = []
        var start: Int?
        var depth = 0
        for y in 0...height {
            let protrusion = y < height && outermost[y] >= 0 ? outermost[y] - baseline : 0
            if protrusion >= rowProtrusion {
                if start == nil {
                    start = y
                    depth = protrusion
                } else {
                    depth = max(depth, protrusion)
                }
            } else if let first = start {
                if y - first >= minimumRows, depth >= acceptedDepths.lowerBound {
                    bulges.append((first...(y - 1), depth))
                }
                start = nil
            }
        }

        guard bulges.count == 2,
              bulges.allSatisfy({ acceptedDepths.contains($0.depth) }),
              bulges[0].rows.count < bulges[1].rows.count
        else {
            return []
        }

        let power = bulges[0]
        let rocker = bulges[1]
        let middleRow = rocker.rows.lowerBound + rocker.rows.count / 2
        func button(_ key: HardwareKey, group: Int, rows: Range<Int>, depth: Int) -> SkinHardwareButton {
            SkinHardwareButton(
                key: key,
                group: group,
                rect: CGRect(x: baseline + 1, y: rows.lowerBound, width: depth, height: rows.count),
                baseline: baseline,
                depth: depth
            )
        }
        return [
            button(.power, group: 0, rows: power.rows.lowerBound..<(power.rows.upperBound + 1), depth: power.depth),
            button(.volumeUp, group: 1, rows: rocker.rows.lowerBound..<middleRow, depth: rocker.depth),
            button(.volumeDown, group: 1, rows: middleRow..<(rocker.rows.upperBound + 1), depth: rocker.depth),
        ]
    }
}

/// The frame artwork split for movable buttons: the base is the artwork
/// with every button cleared, each sprite holds exactly the pixels its key
/// lost, and each stem is a sprite's innermost column (stretched across the
/// gap a sprite leaves when it slides outward). Drawn at rest, sprites under
/// the base, it gives back the artwork's pixels exactly: the base and the
/// sprites share no pixel.
///
/// Built from the installed SDK artwork at run time; none of it is ever
/// stored.
public struct SkinButtonArt: @unchecked Sendable {
    /// The artwork, fully cleared beyond the baseline on rows y0−3…y1+3 of
    /// each button group. Premultiplied sRGB RGBA, the artwork's pixel size.
    public let base: CGImage
    /// The cleared pixels, per key (the rocker's split at its midpoint).
    public let sprites: [HardwareKey: CGImage]
    /// The 1-px innermost column of each sprite.
    public let stems: [HardwareKey: CGImage]
    /// Where each sprite (and its stem, one column wide) sits at rest, in
    /// artwork px, top-left based.
    public let spriteRects: [HardwareKey: CGRect]
    public let buttons: [SkinHardwareButton]

    /// Rows cleared above and below each group's bulge, so its
    /// anti-aliased ends move with the sprite.
    static let rowMargin = 3

    /// Splits `artworkURL` for `buttons` (a `SkinButtonScanner` result for
    /// the same file). Nil when the artwork does not decode or a button lies
    /// outside it.
    public static func make(artworkURL: URL, buttons: [SkinHardwareButton]) -> SkinButtonArt? {
        guard !buttons.isEmpty,
              Set(buttons.map(\.key)).count == buttons.count,
              var bitmap = SkinArtworkBitmap(url: artworkURL)
        else {
            return nil
        }
        let bounds = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
        guard buttons.allSatisfy({ bounds.contains($0.rect) && $0.baseline + 1 < bitmap.width }) else {
            return nil
        }

        // Each group's cleared rows, shared out among its keys top to
        // bottom: the first key of a group also takes the margin above it,
        // the last the margin below. A margin never reaches into the next
        // button's rows, so no pixel lands in two sprites.
        let ordered = buttons.sorted { $0.rect.minY < $1.rect.minY }
        var spriteRects: [HardwareKey: CGRect] = [:]
        var previousBottom = 0
        for (index, button) in ordered.enumerated() {
            let next = index + 1 < ordered.count ? ordered[index + 1] : nil
            let nextTop = next.map { Int($0.rect.minY) } ?? bitmap.height
            let opensGroup = index == 0 || ordered[index - 1].group != button.group
            let closesGroup = next?.group != button.group
            let top = opensGroup
                ? max(previousBottom, Int(button.rect.minY) - rowMargin)
                : Int(button.rect.minY)
            let bottom = closesGroup ? min(nextTop, Int(button.rect.maxY) + rowMargin) : nextTop
            guard bottom > top else { return nil }
            let left = button.baseline + 1
            spriteRects[button.key] = CGRect(x: left, y: top, width: bitmap.width - left, height: bottom - top)
            previousBottom = bottom
        }

        var sprites: [HardwareKey: CGImage] = [:]
        var stems: [HardwareKey: CGImage] = [:]
        for (key, rect) in spriteRects {
            guard let sprite = bitmap.copyImage(rect),
                  let stem = bitmap.copyImage(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height))
            else {
                return nil
            }
            sprites[key] = sprite
            stems[key] = stem
        }
        for rect in spriteRects.values {
            bitmap.clear(rect)
        }
        guard let base = bitmap.image() else { return nil }
        return SkinButtonArt(base: base, sprites: sprites, stems: stems, spriteRects: spriteRects, buttons: buttons)
    }
}

/// A decoded artwork as premultiplied sRGB RGBA bytes, top row first.
struct SkinArtworkBitmap {
    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]

    /// Decodes `url` through ImageIO; nil when it does not decode.
    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        self.init(image: image)
    }

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            // Bitmap memory is top-down: row 0 is the image's top row.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Clears `rect` (whole pixels, inside the bitmap) to transparent.
    mutating func clear(_ rect: CGRect) {
        let columns = Int(rect.minX)..<Int(rect.maxX)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let row = y * width * 4
            pixels.replaceSubrange(
                (row + columns.lowerBound * 4)..<(row + columns.upperBound * 4),
                with: repeatElement(0, count: columns.count * 4)
            )
        }
    }

    /// A copy of `rect` (whole pixels, inside the bitmap) as an image.
    func copyImage(_ rect: CGRect) -> CGImage? {
        let x = Int(rect.minX)
        let cropWidth = Int(rect.width)
        let cropHeight = Int(rect.height)
        guard cropWidth > 0, cropHeight > 0 else { return nil }
        var crop: [UInt8] = []
        crop.reserveCapacity(cropWidth * cropHeight * 4)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let start = (y * width + x) * 4
            crop.append(contentsOf: pixels[start..<(start + cropWidth * 4)])
        }
        return Self.makeImage(crop, width: cropWidth, height: cropHeight)
    }

    /// The whole bitmap as an image.
    func image() -> CGImage? {
        Self.makeImage(pixels, width: width, height: height)
    }

    private static func makeImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData)
        else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
