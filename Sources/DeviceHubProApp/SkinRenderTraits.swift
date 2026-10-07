import AppKit
import DeviceHubProKit

/// Everything the skin compositors need to know about a display's shape,
/// measured once from a variant's artwork and mask:
///
/// - `hasTransparentOpening`: the artwork paints the screen area transparently
///   (modern skins). The compositor clips the screen itself instead of relying
///   on the artwork.
/// - `openingCornerRadius`: the corner arc of that transparent opening in
///   layout units (the artwork's pixels for SDK skins, whose artwork is
///   drawn one pixel per layout unit; a downsampled artwork measures the
///   same value). It is usually *wider* than the device's screen corner —
///   ≈180 against the declared 99 for `pixel_10_pro`, ≈120 against the
///   device's 85 for the fold's inner screen — and it caps the corner the
///   compositors clip the screen to (`ScreenCornerPolicy`).
/// - `glassColor`: the artwork's color right at the opening's straight
///   edges, used to fill the opening under the live video, which shows
///   before the first frame and in letterbox bars (a flat black would break
///   light-bezel skins like `pixel_tablet`), and which the artwork's
///   anti-aliased edge blends with.
/// - `bezelColor`: the average bezel color a little outside the opening's
///   corner arcs; the fill's fallback when no straight edge is found.
/// - `isCircularDisplay`: round display (Wear); the screen is clipped to the
///   inscribed circle instead.
struct SkinRenderTraits {
    let isCircularDisplay: Bool
    let hasTransparentOpening: Bool
    let openingCornerRadius: CGFloat?
    let bezelColor: NSColor?
    let glassColor: NSColor?

    // MARK: - Measurement

    /// - Parameter artworkPixelSize: the artwork file's full pixel size when
    ///   `artwork` is a downsampled decode (the gallery's); nil when
    ///   `artwork` is the full-size image. The artwork is placed by its
    ///   natural size (`SkinDisplay.artworkRect(pixelSize:)`), which a
    ///   downsampled decode no longer carries.
    static func measure(
        artwork: NSImage?,
        mask: NSImage?,
        display: SkinDisplay,
        artworkPixelSize: CGSize? = nil
    ) -> SkinRenderTraits {
        let circular = mask.map(isCircularDisplay(mask:)) ?? false
        guard let artwork,
              let pixels = ArtworkPixels(image: artwork),
              display.layoutSize.width > 0, display.layoutSize.height > 0
        else {
            return SkinRenderTraits(
                isCircularDisplay: circular,
                hasTransparentOpening: false,
                openingCornerRadius: nil,
                bezelColor: nil,
                glassColor: nil
            )
        }
        let geometry = DisplayGeometry(
            pixels: pixels,
            display: display,
            naturalSize: artworkPixelSize
                ?? CGSize(width: pixels.width, height: pixels.height)
        )
        let transparentOpening = hasTransparentOpening(pixels: pixels, geometry: geometry)
        let radius = transparentOpening ? openingRadius(pixels: pixels, geometry: geometry) : nil
        let bezel = transparentOpening
            ? bezelColor(pixels: pixels, geometry: geometry, openingRadius: radius)
            : nil
        return SkinRenderTraits(
            isCircularDisplay: circular,
            hasTransparentOpening: transparentOpening,
            openingCornerRadius: radius.map { $0 / geometry.pixelsPerLayoutUnit },
            bezelColor: bezel,
            glassColor: transparentOpening ? glassColor(pixels: pixels, geometry: geometry) : nil
        )
    }

    /// How far a modern skin's foreground mask fills the screen's corners
    /// (the emulator draws it over the screen), in layout units. It matches
    /// the artwork's opening within 4 units on every installed skin but
    /// `pixel_8a`, which ships the Pixel 8's mask: 88.8 over its 55.7
    /// opening. The static preview keeps the mask's camera lens and leaves
    /// these corners out; the live stage never draws a modern mask, so this
    /// is not part of the traits it measures on the main thread.
    ///
    /// Walks the display-sized mask's top-left diagonal past any clear
    /// pixels (an outer corner cropped off) and the opaque fill to the first
    /// clear pixel, and solves the circular arc for R (inset = R(1 − 1/√2)).
    /// Nil when the corner is not filled. The walk is whole pixels, so on a
    /// downsampled mask the radius is good to about 3.4 mask pixels.
    static func maskCornerRadius(mask: NSImage, display: SkinDisplay) -> CGFloat? {
        guard let pixels = ArtworkPixels(image: mask), display.displaySize.width > 0 else { return nil }
        let limit = min(pixels.width, pixels.height) / 2
        var step = 0
        while step < limit, pixels.alpha(x: step, y: step) < 128 { step += 1 }
        let fillStart = step
        while step < limit, pixels.alpha(x: step, y: step) >= 128 { step += 1 }
        guard step > fillStart, step < limit else { return nil }
        let radius = CGFloat(step) / (1 - 1 / sqrt(2))
        return radius * display.displaySize.width / CGFloat(pixels.width)
    }

    /// Whether the artwork's screen area is transparent: sample the display
    /// rect's centre and require a transparent pixel.
    private static func hasTransparentOpening(
        pixels: ArtworkPixels,
        geometry: DisplayGeometry
    ) -> Bool {
        let x = min(max(Int(geometry.midX), 0), pixels.width - 1)
        let y = min(max(Int(geometry.midY), 0), pixels.height - 1)
        return pixels.alpha(x: x, y: y) < 128
    }

    /// The opening's corner arc radius in artwork pixels. Sample a row a
    /// little below the display's top edge, walk from the display's left edge
    /// to the opening boundary (the first transparent pixel after the bezel),
    /// and solve the circular arc for R:
    ///
    ///   inset = R - sqrt(R² - (R - dy)²)  →  R = inset + dy + sqrt(2·inset·dy)
    private static func openingRadius(
        pixels: ArtworkPixels,
        geometry: DisplayGeometry
    ) -> CGFloat? {
        let dy = min(max(CGFloat(pixels.height) / 120, 8), 40)
        let sampleRow = Int(geometry.originY + dy)
        guard sampleRow < pixels.height else { return nil }
        var seenOpaque = false
        var boundary = -1
        let maxX = min(Int(geometry.originX + geometry.width), pixels.width)
        for x in Int(geometry.originX)..<maxX {
            let alpha = pixels.alpha(x: x, y: sampleRow)
            if alpha >= 128 { seenOpaque = true }
            if seenOpaque, alpha < 128 {
                boundary = x
                break
            }
        }
        guard boundary > Int(geometry.originX), seenOpaque else { return nil }
        let inset = CGFloat(boundary) - geometry.originX
        let radius = inset + dy + sqrt(2 * inset * dy)
        guard radius.isFinite, radius < CGFloat(max(pixels.width, pixels.height)) else {
            return nil
        }
        return radius
    }

    /// The bezel color just outside the opening: around every corner arc,
    /// step outwards along several rays and average the first opaque pixels
    /// found. A single corner-diagonal ray is not enough — artworks crop the
    /// phone's outer corner at the canvas edge (pixel_10_pro is fully
    /// transparent along that diagonal). Returns nil when nothing opaque is
    /// found (the ring then falls back to black).
    private static func bezelColor(
        pixels: ArtworkPixels,
        geometry: DisplayGeometry,
        openingRadius: CGFloat?
    ) -> NSColor? {
        guard let openingRadius, openingRadius > 0 else { return nil }
        let diagonal = 1 / sqrt(2)
        // Arc centre and outward corner bisector per display corner.
        let corners: [(cx: CGFloat, cy: CGFloat, bx: CGFloat, by: CGFloat)] = [
            (geometry.originX + openingRadius, geometry.originY + openingRadius, -diagonal, -diagonal),
            (geometry.originX + geometry.width - openingRadius, geometry.originY + openingRadius, diagonal, -diagonal),
            (geometry.originX + openingRadius, geometry.originY + geometry.height - openingRadius, -diagonal, diagonal),
            (geometry.originX + geometry.width - openingRadius, geometry.originY + geometry.height - openingRadius, diagonal, diagonal),
        ]
        // Rays fanned around each corner bisector; the extreme diagonal is
        // included but not relied upon.
        let rayAngles: [CGFloat] = [-60, -45, -30, -15, 0, 15, 30, 45, 60]
        var total = (r: 0, g: 0, b: 0, n: 0)
        for corner in corners {
            for degrees in rayAngles {
                let angle = degrees * .pi / 180
                let ux = corner.bx * cos(angle) - corner.by * sin(angle)
                let uy = corner.bx * sin(angle) + corner.by * cos(angle)
                var samples = 0
                var distance: CGFloat = 2
                while distance <= 24, samples < 4 {
                    let radius = openingRadius + distance
                    let x = Int((corner.cx + ux * radius).rounded())
                    let y = Int((corner.cy + uy * radius).rounded())
                    if x >= 0, x < pixels.width, y >= 0, y < pixels.height,
                       pixels.alpha(x: x, y: y) >= 200
                    {
                        let rgb = pixels.rgb(x: x, y: y)
                        total.r += rgb.r
                        total.g += rgb.g
                        total.b += rgb.b
                        total.n += 1
                        samples += 1
                    }
                    distance += 1
                }
            }
        }
        guard total.n > 0 else { return nil }
        return NSColor(
            srgbRed: CGFloat(total.r) / CGFloat(total.n) / 255,
            green: CGFloat(total.g) / CGFloat(total.n) / 255,
            blue: CGFloat(total.b) / CGFloat(total.n) / 255,
            alpha: 1
        )
    }

    /// The glass color at the opening's straight edges: the median, channel
    /// by channel, of the first opaque pixel (alpha ≥ 128) found walking
    /// outward, perpendicular to the edge, from every 4th row or column over
    /// the middle half of each of the four edges. That pixel is the one the
    /// artwork's anti-aliased step blends with the backing under it; the
    /// corner rays `bezelColor` averages start 2 pixels out and run past it,
    /// where the glass may already be lighter (the fold cover: (3, 3, 3)
    /// here, (15, 15, 15) there). The median ignores the odd highlight an
    /// edge walk lands on. Nil when no walk finds an opaque pixel.
    private static func glassColor(pixels: ArtworkPixels, geometry: DisplayGeometry) -> NSColor? {
        // Walks start a few pixels inside the display rect, in the
        // transparent opening, so an opening that ends a pixel short of the
        // rect is still entered from inside.
        let inset = 4
        let left = Int(geometry.originX.rounded(.down)) + inset
        let top = Int(geometry.originY.rounded(.down)) + inset
        let right = Int((geometry.originX + geometry.width).rounded(.up)) - 1 - inset
        let bottom = Int((geometry.originY + geometry.height).rounded(.up)) - 1 - inset
        func middleHalf(from start: CGFloat, length: CGFloat) -> StrideTo<Int> {
            stride(
                from: Int((start + length * 0.25).rounded(.up)),
                to: Int((start + length * 0.75).rounded(.down)),
                by: 4
            )
        }
        var samples: [(r: Int, g: Int, b: Int)] = []
        func walk(x: Int, y: Int, dx: Int, dy: Int) {
            var (x, y) = (x, y)
            while x >= 0, x < pixels.width, y >= 0, y < pixels.height {
                if pixels.alpha(x: x, y: y) >= 128 {
                    samples.append(pixels.rgb(x: x, y: y))
                    return
                }
                x += dx
                y += dy
            }
        }
        for y in middleHalf(from: geometry.originY, length: geometry.height) {
            walk(x: left, y: y, dx: -1, dy: 0)
            walk(x: right, y: y, dx: 1, dy: 0)
        }
        for x in middleHalf(from: geometry.originX, length: geometry.width) {
            walk(x: x, y: top, dx: 0, dy: -1)
            walk(x: x, y: bottom, dx: 0, dy: 1)
        }
        guard !samples.isEmpty else { return nil }
        func median(_ channel: ((r: Int, g: Int, b: Int)) -> Int) -> CGFloat {
            let sorted = samples.map(channel).sorted()
            return CGFloat(sorted[(sorted.count - 1) / 2]) / 255
        }
        return NSColor(srgbRed: median { $0.r }, green: median { $0.g }, blue: median { $0.b }, alpha: 1)
    }

    /// Whether the mask describes a round display (Wear): a square mask that
    /// is transparent inside its inscribed circle and opaque just outside
    /// it, along all four diagonals.
    ///
    /// A geometric test, because a coarse downsample cannot tell a ring
    /// from an outline: the previous check (the mid-edge cells of an 8×8
    /// downsample above 0.2 alpha around a clear centre) also passed for
    /// `pixel_9/mask.webp`, whose 1–2 px opaque edge line comes out at
    /// 0.24–0.50 in those cells at full size, and so clipped the Pixel 9's
    /// live screen to a pill. Phone masks fail the square test (the squarest, the Pixel
    /// 9 and 10 Pro Fold inner displays, are 3.7% off), and a rounded-square
    /// watch face stays clear in the sampled band unless its corner radius
    /// exceeds about 70% of the half side.
    static func isCircularDisplay(mask: NSImage) -> Bool {
        var rect = NSRect(origin: .zero, size: mask.size)
        guard let cg = mask.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return false
        }
        let width = cg.width
        let height = cg.height
        // Square within 2%, so the inscribed circle is the display's shape.
        guard min(width, height) >= 16,
              abs(width - height) * 50 <= max(width, height),
              let pixels = ArtworkPixels(cgImage: cg)
        else {
            return false
        }
        let side = CGFloat(min(width, height))
        // Distances run from the centre along a diagonal, in units of the
        // side: the inscribed circle crosses at 0.5, the corner is at 0.71.
        func alpha(diagonalX: CGFloat, diagonalY: CGFloat, distance: CGFloat) -> Int {
            let offset = distance * side / sqrt(2)
            let x = Int(CGFloat(width) / 2 + diagonalX * offset)
            let y = Int(CGFloat(height) / 2 + diagonalY * offset)
            return pixels.alpha(x: min(max(x, 0), width - 1), y: min(max(y, 0), height - 1))
        }
        let step = 1 / side
        for (dx, dy) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] as [(CGFloat, CGFloat)] {
            // Clear from the centre out to 90% of the circle's radius.
            var distance: CGFloat = 0
            while distance <= 0.45 {
                if alpha(diagonalX: dx, diagonalY: dy, distance: distance) >= 64 { return false }
                distance += step
            }
            // Opaque somewhere just past the circle: a ring mask like
            // `wearos_xl_round`'s is only about 0.02–0.08 side wide there.
            var opaque = false
            distance = 0.5
            while distance <= 0.56, !opaque {
                opaque = alpha(diagonalX: dx, diagonalY: dy, distance: distance) >= 192
                distance += step
            }
            if !opaque { return false }
        }
        return true
    }
}

/// The display rectangle in the measured artwork's pixels.
private struct DisplayGeometry {
    let originX: CGFloat
    let originY: CGFloat
    let width: CGFloat
    let height: CGFloat

    /// Artwork pixels per layout unit (1 for full-size SDK artwork).
    let pixelsPerLayoutUnit: CGFloat

    var midX: CGFloat { originX + width / 2 }
    var midY: CGFloat { originY + height / 2 }

    /// - Parameter naturalSize: the artwork file's full pixel size. The
    ///   artwork sits at `display.artworkRect(pixelSize:)` in the layout; a
    ///   downsampled decode shrinks it uniformly by `pixels / naturalSize`.
    init(pixels: ArtworkPixels, display: SkinDisplay, naturalSize: CGSize) {
        let decode = CGFloat(pixels.width) / max(naturalSize.width, 1)
        let placement = display.artworkRect(pixelSize: naturalSize)
        let scale = display.artworkScale(pixelSize: naturalSize) * decode
        pixelsPerLayoutUnit = scale
        originX = (display.origin.x - placement.minX) * scale
        originY = (display.origin.y - placement.minY) * scale
        width = display.displaySize.width * scale
        height = display.displaySize.height * scale
    }
}

/// The artwork's pixels, redrawn into a buffer this value owns with one fixed
/// layout (8-bit RGBA, premultiplied, big-endian, sRGB), so every source
/// format reads the same: 16-bit PNGs, little-endian BGRA decodes, gray or
/// indexed images. The image's own data provider is never borrowed (a copied
/// `CFData` would be released while its pointer was still in use).
private struct ArtworkPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(image: NSImage) {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        self.init(cgImage: cg)
    }

    init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.setBlendMode(.copy)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Alpha at a pixel, row 0 at the top.
    func alpha(x: Int, y: Int) -> Int {
        Int(bytes[(y * width + x) * 4 + 3])
    }

    /// Straight (un-premultiplied) color at a pixel, row 0 at the top.
    func rgb(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let offset = (y * width + x) * 4
        let alpha = Int(bytes[offset + 3])
        guard alpha > 0 else { return (0, 0, 0) }
        func straight(_ value: UInt8) -> Int {
            min(255, (Int(value) * 255 + alpha / 2) / alpha)
        }
        return (straight(bytes[offset]), straight(bytes[offset + 1]), straight(bytes[offset + 2]))
    }
}
