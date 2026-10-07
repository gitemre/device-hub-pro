import AppKit
import ImageIO
import Observation
import DeviceHubProKit

/// Renders a card-sized device preview from skin artwork: the background
/// frame, a placeholder screen in the layout's display rect, and the
/// foreground mask (bezel shading, camera cutout) on top; or, for a device
/// without a skin, its vector body (`renderVector`).
///
/// The screen-shape decisions (transparent cutout, opening corner radius,
/// round display) come from `SkinRenderTraits`, measured from the same
/// downsampled artwork the preview draws, and the screen corner from
/// `ScreenCornerPolicy`, as on the live stage; the rects come from the one
/// plan every consumer draws (`DeviceCompositionPlanner.skin`).
enum SkinThumbnail {
    static let height: CGFloat = 230

    /// Renders a preview `height` points tall at `scale` pixels per point.
    /// Every layer is decoded at the size it is drawn (SDK artwork is up to
    /// ~3000 px tall, ~30 MB decoded per skin), so this is safe to run off
    /// the main thread and never holds full-size artwork.
    ///
    /// - Parameter deviceCornerRadius: the device's own screen corner in
    ///   layout units (`ScreenCornerPolicy.deviceRadius(of:displaySize:)`,
    ///   from the shapes the AVD last reported); nil falls back to the skin.
    static func render(
        variant: SkinVariant,
        height: CGFloat = SkinThumbnail.height,
        scale: CGFloat,
        deviceCornerRadius: CGFloat? = nil
    ) -> CGImage? {
        guard let display = variant.layout?.preferred else {
            return frameOnly(variant: variant, height: height, scale: scale)
        }
        let previewScale = height / max(display.layoutSize.height, 1)
        let size = NSSize(
            width: max(display.layoutSize.width * previewScale, 1),
            height: height
        )
        guard let background = backgroundArtwork(
            for: display,
            in: variant.directory,
            pointsPerUnit: previewScale,
            scale: scale
        ) else {
            return nil
        }
        let backgroundPixels = max(size.width, size.height) * scale

        let screenPixels = max(display.displaySize.width, display.displaySize.height) * previewScale * scale
        let mask = display.maskImage.flatMap {
            decode(named: $0, in: variant.directory, maxPixelSize: screenPixels)
        }
        let overlay = display.overlayImage.flatMap {
            decode(named: $0, in: variant.directory, maxPixelSize: backgroundPixels)
        }
        // Measured from the full-size artwork, as the live stage does, not
        // from the drawn downsample: the opening's corner is solved from a
        // row a few pixels under the top edge, and on a card-sized decode
        // (0.09 pixel per layout unit) that row is below the arc and the
        // inset is whole-pixel noise: `pixel_7a`'s 45 came out 138 at card
        // height, 805 (a pill) at 520 px, so the placeholder's corners did
        // not fit the opening and the artwork showed through them.
        let traits = measuredTraits(for: variant, display: display)

        let corner = ScreenCornerPolicy.corner(
            deviceRadius: deviceCornerRadius,
            displaySize: display.displaySize,
            declaredRadius: display.cornerRadius,
            openingRadius: traits.openingCornerRadius,
            hasTransparentOpening: traits.hasTransparentOpening,
            isRoundDisplay: traits.isCircularDisplay
        )
        // The live stage's plan (`FramedBodyLayers`): the frame artwork at
        // its natural size (the canvas is the layout box and clips any
        // overhang), and under a modern skin's transparent opening a
        // backing of the artwork's glass colour.
        let plan = DeviceCompositionPlanner.skin(
            display: display,
            artworkPixelSize: background.pixelSize,
            corner: corner,
            backing: traits.hasTransparentOpening && !traits.isCircularDisplay
                ? DeviceComposition.Backing(
                    cornerRadius: traits.openingCornerRadius ?? corner.radius,
                    color: RGBA(sRGB: traits.glassColor ?? traits.bezelColor ?? .black)
                )
                : nil,
            drawsLegacyMask: mask != nil && !traits.hasTransparentOpening,
            hasOverlay: overlay != nil
        )
        let placed = plan.placed(pointsPerUnit: previewScale, pixelScale: scale)
        // The plan is top-left based; the graphics context is not.
        func flipped(_ rect: CGRect) -> NSRect {
            NSRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let screen = flipped(placed.screen)
        let artworkFrame = flipped(placed.artworkFrame ?? placed.screen)
        // A modern skin's mask fills the screen's corners (the emulator's
        // own clip, about the artwork's opening) and paints the camera lens.
        // The live stage does not draw it; here it is kept for the lens
        // only, clipped inside its corner fill (plus the measurement's 4
        // mask pixels), so the corners do not round the screen off again.
        let maskClipRadius: CGFloat? = mask.flatMap { mask in
            guard traits.hasTransparentOpening, !traits.isCircularDisplay else { return nil }
            let fill = SkinRenderTraits.maskCornerRadius(mask: NSImage(cgImage: mask, size: .zero), display: display)
            let reach = max(fill ?? 0, traits.openingCornerRadius ?? 0)
            let slack = 4 * display.displaySize.width / CGFloat(max(mask.width, 1))
            return (reach + slack) * previewScale
        }

        return draw(size: size, scale: scale) { context in
            let frame = CGRect(origin: .zero, size: size)
            // Under the artwork, the backing outset 2 pixels past the
            // screen, so the artwork's anti-aliased opening edge lies over
            // it: over the transparent canvas instead, that edge and the
            // placeholder's shared the pixel an edge falls in at a
            // fractional scale and left a see-through line (the live
            // stage's seam, `FramedBodyLayers`).
            if let backing = placed.backingFrame.map(flipped), let color = placed.backingColor {
                // CoreGraphics traps on a corner wider than half the rect.
                let radius = min(max(placed.backingRadius, 0), backing.width / 2, backing.height / 2)
                context.addPath(CGPath(roundedRect: backing, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(color.sRGBColor)
                context.fillPath()
            }
            // The placeholder sits on the artwork, clipped to the screen
            // corner, as the live video does: drawn under the artwork, the
            // artwork's opening would cut it at the opening's radius instead,
            // and the corner would change shape the moment the device went
            // live. Legacy artwork can also be opaque over the screen area.
            // A round watch's ring opens a hair wider than the display's
            // inscribed circle at 3 and 9 o'clock (a clear sliver there at
            // 460 and 1040 px): the placeholder goes under the artwork too,
            // 2 pixels outset, and the ring's anti-aliased edge lies over it.
            if corner.source == .roundDisplay {
                NSGraphicsContext.saveGraphicsState()
                let outset = 2 / scale
                let under = screen.insetBy(dx: -outset, dy: -outset)
                NSBezierPath(ovalIn: under).addClip()
                drawPlaceholderScreen(in: under)
                NSGraphicsContext.restoreGraphicsState()
            }
            context.draw(background.image, in: artworkFrame)
            NSGraphicsContext.saveGraphicsState()
            if corner.source == .roundDisplay {
                // Round displays (Wear): the mask only carries a ring shadow,
                // so the screen itself is clipped to the inscribed circle.
                NSBezierPath(ovalIn: screen).addClip()
            } else if placed.screenCornerRadius > 0 {
                let radius = placed.screenCornerRadius
                NSBezierPath(roundedRect: screen, xRadius: radius, yRadius: radius).addClip()
            } else {
                NSBezierPath(rect: screen).addClip()
            }
            drawPlaceholderScreen(in: screen)
            NSGraphicsContext.restoreGraphicsState()

            // Masks are display-sized (verified across all SDK skins); the punch
            // hole and corner arcs only align when drawn at the display rect.
            if let mask {
                NSGraphicsContext.saveGraphicsState()
                if let maskClipRadius {
                    NSBezierPath(roundedRect: screen, xRadius: maskClipRadius, yRadius: maskClipRadius).addClip()
                }
                context.draw(mask, in: screen)
                NSGraphicsContext.restoreGraphicsState()
            }

            // Legacy top overlay (rounded corners, bezel shading over the edges),
            // stretched to the layout box: see `FramedMirrorView.overlayLayer`.
            if let overlay {
                context.draw(overlay, in: frame)
            }

            // A round watch whose artwork is an opaque square (the SDK's
            // small and large Wear OS skins paint the ring on a #202020
            // tile): keep the ring's own circle, so the preview is round
            // on any background.
            if traits.isCircularDisplay, let fraction = Self.roundOutlineRadiusFraction(of: background.image) {
                let art = artworkFrame
                let radius = fraction * art.width
                // Everything outside the circle goes: clip to the outside
                // (even-odd) and clear.
                context.saveGState()
                context.addRect(frame)
                context.addEllipse(in: CGRect(
                    x: art.midX - radius, y: art.midY - radius, width: radius * 2, height: radius * 2
                ))
                context.clip(using: .evenOdd)
                context.clear(frame)
                context.restoreGState()
            }
        }
    }

    private static let traitsLock = NSLock()
    nonisolated(unsafe) private static var traitsCache: [String: SkinRenderTraits] = [:]

    /// `variant`'s display traits measured from its full-size artwork
    /// (`SkinThumbnailCache.measuredTraits`, what the live stage measures),
    /// once per variant: the artwork is decoded for the measurement only.
    static func measuredTraits(for variant: SkinVariant, display: SkinDisplay) -> SkinRenderTraits {
        let key = "\(variant.directory.path)#\(variant.id)#\(display.backgroundImage ?? "")"
        traitsLock.lock()
        let cached = traitsCache[key]
        traitsLock.unlock()
        if let cached { return cached }
        let measured = SkinThumbnailCache.measuredTraits(for: variant, display: display)
        traitsLock.lock()
        traitsCache[key] = measured
        traitsLock.unlock()
        return measured
    }

    /// For artwork that is a round device on an opaque square (its corners
    /// are opaque and all one colour): the radius of the device's outer
    /// edge as a fraction of the image's width, found as the first pixel
    /// along the middle row that leaves the corner's colour. Nil when the
    /// corners are transparent (the artwork already has its own outline) or
    /// the row never leaves the corner colour.
    static func roundOutlineRadiusFraction(of image: CGImage) -> CGFloat? {
        let width = image.width, height = image.height
        guard width > 8, height > 8,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }
        let corner = pixel(1, 1)
        guard corner.a >= 250 else { return nil }
        let row = height / 2
        for x in 0..<(width / 2) {
            let p = pixel(x, row)
            let difference = abs(p.r - corner.r) + abs(p.g - corner.g) + abs(p.b - corner.b)
            if p.a < 250 || difference > 24 {
                // Half a pixel of anti-aliasing past the edge.
                return (CGFloat(width) / 2 - CGFloat(x) + 0.5) / CGFloat(width)
            }
        }
        return nil
    }

    /// A round watch's frame artwork with the opaque square around its ring
    /// cleared (`roundOutlineRadiusFraction`), for the live stage: the same
    /// circle `render` clips its previews to, so the stage, the sidebar and
    /// the catalog all show a round watch. Same pixel size and point size as
    /// `image`; nil when the artwork needs no clip (its corners are already
    /// transparent, or it is not a ring on a tile).
    static func roundClipped(_ image: NSImage) -> NSImage? {
        let pixels = image.artworkPixelSize
        let width = Int(pixels.width), height = Int(pixels.height)
        var rect = CGRect(origin: .zero, size: pixels)
        // The artwork's own bitmap when it has one: `cgImage(forProposedRect:)` renders
        // at the screen's backing scale, so on a Retina screen it came back twice as large.
        let bitmap = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide }?.cgImage
        guard width > 8, height > 8,
              let source = bitmap ?? image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let fraction = roundOutlineRadiusFraction(of: source),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(source, in: frame)
        let radius = fraction * CGFloat(width)
        // Everything outside the circle goes: clip to the outside (even-odd) and clear.
        context.addRect(frame)
        context.addEllipse(in: CGRect(
            x: frame.midX - radius, y: frame.midY - radius, width: radius * 2, height: radius * 2
        ))
        context.clip(using: .evenOdd)
        context.clear(frame)
        guard let clipped = context.makeImage() else { return nil }
        // An explicit bitmap rep: `NSImage(cgImage:size:)`'s snapshot rep reports its
        // pixels at the screen's backing scale (twice the artwork on a Retina screen).
        let rep = NSBitmapImageRep(cgImage: clipped)
        rep.size = image.size
        let result = NSImage(size: image.size)
        result.addRepresentation(rep)
        return result
    }

    /// A device without a skin, `height` points tall at `scale` pixels per
    /// point: its vector body drawn by `DeviceCompositionRenderer` (the
    /// bands, then the placeholder screen clipped to the device's corner,
    /// then the camera cutout), as a framed screenshot draws it. Nil for a
    /// skin plan or an empty one. Safe off the main thread.
    static func renderVector(
        _ composition: DeviceComposition,
        height: CGFloat = SkinThumbnail.height,
        scale: CGFloat
    ) -> CGImage? {
        guard composition.layoutSize.height > 0, height > 0, scale > 0 else { return nil }
        let pixelsPerUnit = height * scale / composition.layoutSize.height
        return DeviceCompositionRenderer.render(composition, pixelsPerUnit: pixelsPerUnit) { context, rect in
            // The renderer draws in pixels; the placeholder is laid out in
            // points, like the skin previews' (`draw(size:scale:_:)`).
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            drawPlaceholderScreen(in: NSRect(
                x: rect.minX / scale,
                y: rect.minY / scale,
                width: rect.width / scale,
                height: rect.height / scale
            ))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            // An Apple device's own sensor bar (the Dynamic Island) over the
            // placeholder, as Device Hub's stopped device shows it.
            if case let .appleChrome(body) = composition.body, body.quarterTurns == 0 {
                drawSensorBar(body.sensorBar, in: rect, context: context)
                if body.hasDynamicIsland {
                    drawDynamicIsland(pixelsPerPoint: rect.width / max(body.layout.screen.width, 1), in: rect, context: context)
                }
            }
        }
    }

    /// The Dynamic Island every such iPhone has: a black capsule 126 x 37 pt,
    /// 11 pt below the screen's top edge, centred.
    private static func drawDynamicIsland(pixelsPerPoint k: CGFloat, in screen: CGRect, context: CGContext) {
        let width = 126 * k, height = 37 * k
        let island = CGRect(x: screen.midX - width / 2, y: screen.maxY - 11 * k - height, width: width, height: height)
        context.saveGState()
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.addPath(CGPath(roundedRect: island, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    /// The device type's sensor-bar PDF (one page as wide as the screen in
    /// points, full of the bar at its top) drawn across the top of `screen`
    /// (y-up pixels).
    private static func drawSensorBar(_ url: URL?, in screen: CGRect, context: CGContext) {
        guard let url, let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return }
        let width = screen.width
        let height = width * box.height / box.width
        context.saveGState()
        context.translateBy(x: screen.minX, y: screen.maxY - height)
        context.scaleBy(x: width / box.width, y: height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// Frame artwork alone, for skins whose layout is missing or unparseable.
    private static func frameOnly(variant: SkinVariant, height: CGFloat, scale: CGFloat) -> CGImage? {
        // Artwork is at most a few times wider than tall; decode generously
        // and scale to the requested height.
        guard let art = fallbackArtwork(in: variant.directory, maxPixelSize: height * scale * 3),
              art.height > 0
        else {
            return nil
        }
        let aspect = CGFloat(art.width) / CGFloat(art.height)
        let size = NSSize(width: max(height * aspect, 1), height: height)
        return draw(size: size, scale: scale) { context in
            context.draw(art, in: CGRect(origin: .zero, size: size))
        }
    }

    /// Draws into a fresh sRGB bitmap of `size` points at `scale`, with an
    /// AppKit graphics context current on this thread for the drawing block.
    private static func draw(
        size: NSSize,
        scale: CGFloat,
        _ body: (CGContext) -> Void
    ) -> CGImage? {
        let pixelsWide = max(Int((size.width * scale).rounded(.up)), 1)
        let pixelsHigh = max(Int((size.height * scale).rounded(.up)), 1)
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: pixelsWide,
                height: pixelsHigh,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// The frame artwork (the layout's background, else the directory's
    /// fallback) decoded at the size it is drawn, with the file's natural
    /// pixel size, which places it (`SkinDisplay.artworkRect(pixelSize:)`)
    /// and which the downsampled decode no longer carries.
    private static func backgroundArtwork(
        for display: SkinDisplay,
        in directory: URL,
        pointsPerUnit: CGFloat,
        scale: CGFloat
    ) -> (image: CGImage, pixelSize: CGSize)? {
        let declared = [display.backgroundImage].compactMap { $0 }.filter { !$0.isEmpty }
        let names = declared + fallbackArtworkNames(in: directory)
        for name in names {
            guard let natural = pixelSize(named: name, in: directory) else { continue }
            let placement = display.artworkRect(pixelSize: natural)
            let drawnPixels = max(placement.width, placement.height) * pointsPerUnit * scale
            if let image = decode(named: name, in: directory, maxPixelSize: drawnPixels) {
                return (image, natural)
            }
        }
        return nil
    }

    /// An image file's pixel size from its header, without decoding it.
    static func pixelSize(named name: String, in directory: URL) -> CGSize? {
        let url = directory.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Decodes an artwork file no larger than `maxPixelSize` on its longer
    /// side (ImageIO never upscales), or nil.
    static func decode(named name: String?, in directory: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let name, !name.isEmpty else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maxPixelSize.rounded(.up)), 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func loadImage(named name: String?, in directory: URL) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// The directory's frame artwork when the layout declares none (or it is
    /// missing): the `back`/`bezel` images first, then any image.
    static func fallbackArtworkNames(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let preferred = names
            .filter { $0.hasPrefix("back") || $0.hasPrefix("port_back") || $0.contains("bezel") }
            .sorted()
        return (preferred + names.sorted()).filter { $0.hasSuffix(".webp") || $0.hasSuffix(".png") }
    }

    static func fallbackArtwork(in directory: URL) -> NSImage? {
        for name in fallbackArtworkNames(in: directory) {
            if let image = loadImage(named: name, in: directory) {
                return image
            }
        }
        return nil
    }

    private static func fallbackArtwork(in directory: URL, maxPixelSize: CGFloat) -> CGImage? {
        for name in fallbackArtworkNames(in: directory) {
            if let image = decode(named: name, in: directory, maxPixelSize: maxPixelSize) {
                return image
            }
        }
        return nil
    }

    /// A muted fake home screen: gradient wallpaper, status bar, icon grid.
    /// DH's stopped device shows a plain wallpaper-like blue screen — no
    /// app-icon grid. Colors are sampled from a
    /// live 2x DH capture (own unbooted simulator, `AQA probe Stage`, on
    /// `iPhone 17`'s screen): #3a8fcf at the top, #55a9e9 at the bottom —
    /// close to the webp estimate but rendered in `.sRGB` here, not
    /// `.calibratedRGB` (macOS's legacy generic space, off-sRGB enough to
    /// read visibly paler than the reference on this display). Shared by
    /// every device without live content: a skin's display (`render`) and
    /// a skinless/vector body (`renderVector`), Android and Apple alike.
    private static func drawPlaceholderScreen(in rect: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }

        let gradient = NSGradient(
            starting: NSColor(srgbRed: 0.333, green: 0.663, blue: 0.914, alpha: 1),
            ending: NSColor(srgbRed: 0.227, green: 0.561, blue: 0.812, alpha: 1)
        )
        gradient?.draw(in: rect, angle: 90)
    }
}

/// Caches the skin artwork the app shows.
///
/// - Gallery previews (`image(for:height:)`) are rendered off the main thread
///   from artwork decoded at the size it is drawn, and kept within a decoded
///   pixel budget, least recently used out first. The first request returns
///   nil (the views show their placeholder); the view updates by itself once
///   its preview is ready. A skin without renderable artwork is tried again
///   after a while, so one installed meanwhile appears without a relaunch.
/// - A skinless device's vector body (`vectorImage(for:height:)`) is
///   rendered and kept the same way, in the same budget.
/// - The live hero's full-size artwork (`artwork(for:display:)`) and its
///   measured traits stay synchronous (the framed stage lays out with them)
///   and are only loaded for skins actually mirrored; the images are bounded
///   by count. Framed screenshots share the traits but measure a miss off
///   the main actor (`screenCornerMeasuredOffMain`).
/// - A mirrored Pixel skin's side buttons (`buttonArt(for:display:)`) are
///   split out of its frame once, off the main thread, for the main stage;
///   the split is kept per variant, beside the artwork, for the few
///   variants last mirrored.
@MainActor
final class SkinThumbnailCache {
    static let shared = SkinThumbnailCache()

    /// Renders one preview: variant, height in points, pixels per point, and
    /// the device's screen corner in layout units (nil: the skin's).
    typealias Renderer = @Sendable (SkinVariant, CGFloat, CGFloat, CGFloat?) -> CGImage?
    /// Measures a variant's display traits away from the main actor
    /// (`screenCornerMeasuredOffMain`).
    typealias TraitsMeasurer = @Sendable (SkinVariant, SkinDisplay) -> SkinRenderTraits
    /// Renders one vector body: the composition, height in points, pixels
    /// per point.
    typealias VectorRenderer = @Sendable (DeviceComposition, CGFloat, CGFloat) -> CGImage?
    /// Splits one frame artwork file for its side buttons, away from the
    /// main actor (`LiveButtonArt.make`); nil when it has none.
    typealias ButtonArtMaker = @Sendable (URL) -> LiveButtonArt?

    private let costLimit: Int
    private let missRetryInterval: TimeInterval
    private let now: () -> Date
    private let render: Renderer
    private let renderVector: VectorRenderer
    private let makeButtonArt: ButtonArtMaker
    private nonisolated let measureTraits: TraitsMeasurer
    private let renderQueue = DispatchQueue(label: "com.devicehubpro.skin-previews", qos: .utility)

    private var previews: [String: PreviewEntry] = [:]
    private var previewCost = 0
    private var useClock: UInt64 = 0

    private let heroImages = NSCache<NSString, NSImage>()
    private var heroMisses: [String: Date] = [:]
    private var traitsByKey: [String: SkinRenderTraits] = [:]
    /// `stageBackground`'s clipped artwork per variant (`.some(nil)`: no clip needed).
    private var roundedBackgrounds: [String: NSImage?] = [:]
    /// Keyed by the frame artwork's path; one per skin variant mirrored with
    /// its buttons, the least recently asked for dropped past
    /// `buttonArtLimit` (`buttonArtOrder`, oldest first).
    private var buttonArts: [String: ButtonArtEntry] = [:]
    private var buttonArtOrder: [String] = []
    private let buttonArtLimit: Int

    /// - Parameters:
    ///   - costLimit: decoded bytes the gallery previews may hold (64 MB is
    ///     ~150 catalog cards at 2x).
    ///   - missRetryInterval: how long a skin without artwork stays a miss.
    init(
        costLimit: Int = 64 << 20,
        missRetryInterval: TimeInterval = 30,
        now: @escaping () -> Date = Date.init,
        render: @escaping Renderer = {
            SkinThumbnail.render(variant: $0, height: $1, scale: $2, deviceCornerRadius: $3)
        },
        measureTraits: @escaping TraitsMeasurer = { SkinThumbnailCache.measuredTraits(for: $0, display: $1) },
        renderVector: @escaping VectorRenderer = { SkinThumbnail.renderVector($0, height: $1, scale: $2) },
        makeButtonArt: @escaping ButtonArtMaker = { LiveButtonArt.make(artworkURL: $0) },
        buttonArtLimit: Int = 4
    ) {
        self.costLimit = costLimit
        self.buttonArtLimit = max(buttonArtLimit, 1)
        self.missRetryInterval = missRetryInterval
        self.now = now
        self.render = render
        self.renderVector = renderVector
        self.makeButtonArt = makeButtonArt
        self.measureTraits = measureTraits
        // A handful of mirrored skins (a foldable has two variants).
        heroImages.countLimit = 12
    }

    // MARK: - Gallery previews

    /// The preview when it is ready, else nil while it renders off the main
    /// thread; reading it from a view body updates that view once it is.
    ///
    /// `deviceCornerRadius` is an AVD's own screen corner in layout units
    /// (`ScreenCornerPolicy.deviceRadius(of:displaySize:)`); nil draws the
    /// skin's fallback. Previews with different corners are cached apart.
    func image(
        for variant: SkinVariant,
        height: CGFloat = SkinThumbnail.height,
        deviceCornerRadius: CGFloat? = nil
    ) -> NSImage? {
        previewEntry(for: variant, height: height, deviceCornerRadius: deviceCornerRadius).image
    }

    /// The preview, waiting for its render.
    func renderedImage(
        for variant: SkinVariant,
        height: CGFloat = SkinThumbnail.height,
        deviceCornerRadius: CGFloat? = nil
    ) async -> NSImage? {
        let entry = previewEntry(for: variant, height: height, deviceCornerRadius: deviceCornerRadius)
        guard entry.isRendering else { return entry.image }
        return await withCheckedContinuation { entry.waiters.append($0) }
    }

    /// A device without a skin (a stopped skinless AVD): its vector body
    /// `height` points tall (`SkinThumbnail.renderVector`), when it is
    /// ready, else nil while it renders off the main thread; reading it from
    /// a view body updates that view once it is. Kept with the gallery
    /// previews, in their pixel budget.
    func vectorImage(for composition: DeviceComposition, height: CGFloat = SkinThumbnail.height) -> NSImage? {
        vectorEntry(for: composition, height: height).image
    }

    /// The vector image, waiting for its render.
    func renderedVectorImage(for composition: DeviceComposition, height: CGFloat = SkinThumbnail.height) async -> NSImage? {
        let entry = vectorEntry(for: composition, height: height)
        guard entry.isRendering else { return entry.image }
        return await withCheckedContinuation { entry.waiters.append($0) }
    }

    /// The vector image's cache key: the composition's hash and the height.
    /// Every input the drawing uses is in the composition, so two AVDs whose
    /// bodies plan alike share one image.
    static func vectorKey(for composition: DeviceComposition, height: CGFloat) -> String {
        "vector#\(composition.hashValue)#\(Int(height))"
    }

    /// Decoded bytes the cached previews hold.
    var previewBytes: Int { previewCost }

    private func previewEntry(for variant: SkinVariant, height: CGFloat, deviceCornerRadius: CGFloat?) -> PreviewEntry {
        let render = self.render
        return previewEntry(key: Self.previewKey(for: variant, height: height, deviceCornerRadius: deviceCornerRadius)) { scale in
            render(variant, height, scale, deviceCornerRadius)
        }
    }

    private func vectorEntry(for composition: DeviceComposition, height: CGFloat) -> PreviewEntry {
        let renderVector = self.renderVector
        return previewEntry(key: Self.vectorKey(for: composition, height: height)) { scale in
            renderVector(composition, height, scale)
        }
    }

    /// The entry for `key`, its render (at the screens' largest pixel scale)
    /// started off the main thread when it has no image, is not rendering
    /// and is not a recent miss.
    private func previewEntry(key: String, render: @escaping @Sendable (CGFloat) -> CGImage?) -> PreviewEntry {
        let entry = previews[key] ?? {
            let created = PreviewEntry()
            previews[key] = created
            return created
        }()
        useClock += 1
        entry.lastUse = useClock
        let missExpired = entry.missedAt.map { now().timeIntervalSince($0) >= missRetryInterval } ?? true
        if entry.image == nil, !entry.isRendering, missExpired {
            startRender(entry, key: key, render: render)
        }
        return entry
    }

    /// The cache key: skin variant, height and, when an AVD's device reported
    /// one, its screen corner to a hundredth of a layout unit — two AVDs of
    /// one skin whose devices report different corners draw different
    /// previews.
    static func previewKey(for variant: SkinVariant, height: CGFloat, deviceCornerRadius: CGFloat?) -> String {
        let corner = deviceCornerRadius.map { String(format: "%.2f", Double($0)) } ?? "skin"
        return "\(variant.directory.path)#\(variant.id)#\(Int(height))#\(corner)"
    }

    private func startRender(_ entry: PreviewEntry, key: String, render: @escaping @Sendable (CGFloat) -> CGImage?) {
        entry.isRendering = true
        entry.missedAt = nil
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        renderQueue.async {
            let image = render(scale)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(entry, key: key, image: image, scale: scale)
                }
            }
        }
    }

    private func finish(_ entry: PreviewEntry, key: String, image: CGImage?, scale: CGFloat) {
        entry.isRendering = false
        if let image {
            entry.cost = image.bytesPerRow * image.height
            entry.image = NSImage(
                cgImage: image,
                size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            )
            if previews[key] === entry {
                previewCost += entry.cost
                evictPreviews(keeping: key)
            }
        } else {
            entry.missedAt = now()
        }
        let waiters = entry.waiters
        entry.waiters = []
        waiters.forEach { $0.resume(returning: entry.image) }
    }

    private func evictPreviews(keeping key: String) {
        while previewCost > costLimit {
            guard let oldest = previews
                .filter({ $0.key != key && $0.value.image != nil })
                .min(by: { $0.value.lastUse < $1.value.lastUse })
            else {
                return
            }
            previews[oldest.key] = nil
            previewCost -= oldest.value.cost
        }
    }

    // MARK: - Live hero

    /// Measured screen-shape traits for a variant's display (the measurements
    /// decode artwork and scan pixels, so they must not run on every view
    /// refresh).
    func traits(for variant: SkinVariant, display: SkinDisplay) -> SkinRenderTraits {
        let key = Self.traitsKey(for: variant, display: display)
        if let cached = traitsByKey[key] { return cached }
        let art = artwork(for: variant, display: display)
        let measured = SkinRenderTraits.measure(
            artwork: art.background,
            mask: art.mask,
            display: display,
            artworkPixelSize: art.background?.artworkPixelSize
        )
        traitsByKey[key] = measured
        return measured
    }

    /// The screen corner the live stage clips `display` to when the device
    /// reports `shape` (`ScreenCornerPolicy`, with this variant's measured
    /// traits), in layout units.
    func screenCorner(for variant: SkinVariant, display: SkinDisplay, device shape: DisplayShape?) -> ScreenCorner {
        Self.screenCorner(traits: traits(for: variant, display: display), display: display, device: shape)
    }

    /// `screenCorner(for:display:device:)` for framed screenshots, which run
    /// off the main actor and may frame a variant the live stage never
    /// measured (Include Device Frame on with Show Device Frame off, a
    /// fold's other screen): measuring decodes the full-size artwork and
    /// mask and scans them, 20–60 ms per variant. Only the cache lookup and
    /// store run on the main actor; a miss is measured on the caller's
    /// executor (`measureTraits`) from artwork that is not kept.
    nonisolated func screenCornerMeasuredOffMain(
        for variant: SkinVariant,
        display: SkinDisplay,
        device shape: DisplayShape?
    ) async -> ScreenCorner {
        let key = Self.traitsKey(for: variant, display: display)
        let traits: SkinRenderTraits
        if let cached = await cachedTraits(key: key) {
            traits = cached
        } else {
            traits = await keep(measureTraits(variant, display), key: key)
        }
        return Self.screenCorner(traits: traits, display: display, device: shape)
    }

    private nonisolated static func traitsKey(for variant: SkinVariant, display: SkinDisplay) -> String {
        "\(variant.directory.path)#\(variant.id)#\(display.backgroundImage ?? "")"
    }

    private nonisolated static func screenCorner(
        traits: SkinRenderTraits,
        display: SkinDisplay,
        device shape: DisplayShape?
    ) -> ScreenCorner {
        ScreenCornerPolicy.corner(
            device: shape,
            displaySize: display.displaySize,
            declaredRadius: display.cornerRadius,
            openingRadius: traits.openingCornerRadius,
            hasTransparentOpening: traits.hasTransparentOpening,
            isRoundDisplay: traits.isCircularDisplay
        )
    }

    private func cachedTraits(key: String) -> SkinRenderTraits? {
        traitsByKey[key]
    }

    /// Keeps traits measured off the main actor, unless the live stage
    /// measured the variant meanwhile; returns the ones kept.
    private func keep(_ measured: SkinRenderTraits, key: String) -> SkinRenderTraits {
        if let cached = traitsByKey[key] { return cached }
        traitsByKey[key] = measured
        return measured
    }

    /// `traits(for:display:)`'s measurement without the hero cache: the
    /// same full-size artwork and mask, decoded for this call only.
    nonisolated static func measuredTraits(for variant: SkinVariant, display: SkinDisplay) -> SkinRenderTraits {
        let background = SkinThumbnail.loadImage(named: display.backgroundImage, in: variant.directory)
            ?? SkinThumbnail.fallbackArtwork(in: variant.directory)
        return SkinRenderTraits.measure(
            artwork: background,
            mask: SkinThumbnail.loadImage(named: display.maskImage, in: variant.directory),
            display: display,
            artworkPixelSize: background?.artworkPixelSize
        )
    }

    /// The frame artwork the live stage draws: a round watch's artwork is an
    /// opaque square with the ring painted on it, so it is clipped to the
    /// ring's circle (`SkinThumbnail.roundClipped`, the previews' rule) and
    /// the watch shows round on any stage. Every other skin's artwork as it
    /// is. Cached per variant; the traits and the layout keep reading the raw
    /// artwork (`artwork(for:display:)`).
    func stageBackground(_ background: NSImage, traits: SkinRenderTraits, variant: SkinVariant, display: SkinDisplay) -> NSImage {
        guard traits.isCircularDisplay else { return background }
        let key = Self.traitsKey(for: variant, display: display)
        if let cached = roundedBackgrounds[key] { return cached ?? background }
        let clipped = SkinThumbnail.roundClipped(background)
        roundedBackgrounds[key] = .some(clipped)
        return clipped ?? background
    }

    /// Raw frame artwork for the live hero, cached by file path.
    func artwork(for variant: SkinVariant, display: SkinDisplay) -> SkinArtwork {
        SkinArtwork(
            background: cachedImage(named: display.backgroundImage, in: variant.directory)
                ?? cachedFallback(in: variant.directory),
            mask: cachedImage(named: display.maskImage, in: variant.directory),
            overlay: cachedImage(named: display.overlayImage, in: variant.directory)
        )
    }

    // MARK: - Live side buttons

    /// The side buttons of `variant`'s frame split out for the live stage
    /// (`HardwareButtonsLayer`), when they are ready; else nil, and with
    /// `build` the split starts off the main thread (once per artwork: a
    /// frame without buttons is not split again). Reading it from a view
    /// body updates that view once it is ready.
    ///
    /// The split sits beside the artwork (`artwork(for:display:)`), which
    /// the stage keeps drawing while every button rests: its frame without
    /// the buttons (`LiveButtonArt.background`) is drawn only while a
    /// button is out of its place. Drawn with the sprites at rest under it,
    /// the split gives back the artwork's pixels exactly, but minified, the
    /// pieces are filtered apart: at the stage's fit on a 1x display
    /// (≈3.5 artwork pixels per screen pixel) the filter's reach spans a
    /// whole button, and a column inside it drew up to 46 levels off the
    /// artwork drawn whole (88 around the open 9 Pro Fold's), so the stage
    /// hands back to the artwork with a cross-fade
    /// (`HardwareButtonsState.restFade`). Static previews and framed
    /// screenshots keep reading the files.
    ///
    /// A split holds a full-size bitmap of the frame (≈17 MB for the 10
    /// Pro, 20 MB for the open fold), so only the `buttonArtLimit` (4)
    /// variants last asked for are kept: the device on the stage and the
    /// one before it, a foldable's two screens included. A variant asked
    /// for again after it was dropped is split again.
    func buttonArt(for variant: SkinVariant, display: SkinDisplay, build: Bool = true) -> LiveButtonArt? {
        guard let url = Self.buttonArtURL(for: variant, display: display) else { return nil }
        let key = url.path
        let entry = buttonArts[key] ?? {
            let created = ButtonArtEntry()
            buttonArts[key] = created
            return created
        }()
        keepButtonArt(key)
        if build, !entry.isBuilding, !entry.isFinished {
            startButtonArt(entry, url: url)
        }
        return entry.art
    }

    /// Marks `key`'s split as the one last asked for and drops the least
    /// recently asked for past the limit. A split still being made is kept
    /// (its waiters are answered from it).
    private func keepButtonArt(_ key: String) {
        if buttonArtOrder.last != key {
            buttonArtOrder.removeAll { $0 == key }
            buttonArtOrder.append(key)
        }
        while buttonArts.count > buttonArtLimit,
              let oldest = buttonArtOrder.first(where: { $0 != key && buttonArts[$0]?.isBuilding != true })
        {
            buttonArtOrder.removeAll { $0 == oldest }
            buttonArts[oldest] = nil
        }
    }

    /// `buttonArt(for:display:)`, waiting for its split.
    func builtButtonArt(for variant: SkinVariant, display: SkinDisplay) async -> LiveButtonArt? {
        if let art = buttonArt(for: variant, display: display) { return art }
        guard let url = Self.buttonArtURL(for: variant, display: display),
              let entry = buttonArts[url.path], entry.isBuilding
        else {
            return nil
        }
        return await withCheckedContinuation { entry.waiters.append($0) }
    }

    /// Only a declared frame image is split: the one the stage draws.
    private static func buttonArtURL(for variant: SkinVariant, display: SkinDisplay) -> URL? {
        guard let name = display.backgroundImage, !name.isEmpty else { return nil }
        return variant.directory.appendingPathComponent(name)
    }

    private func startButtonArt(_ entry: ButtonArtEntry, url: URL) {
        entry.isBuilding = true
        let make = makeButtonArt
        renderQueue.async {
            let art = make(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(entry, art: art)
                }
            }
        }
    }

    private func finish(_ entry: ButtonArtEntry, art: LiveButtonArt?) {
        entry.isBuilding = false
        entry.isFinished = true
        entry.art = art
        let waiters = entry.waiters
        entry.waiters = []
        waiters.forEach { $0.resume(returning: entry.art) }
    }

    /// `SkinThumbnail.fallbackArtwork` scans the directory and mints a fresh
    /// NSImage per call; cache it by directory so a skin with missing
    /// declared artwork is not re-decoded on every view refresh.
    private func cachedFallback(in directory: URL) -> NSImage? {
        heroImage(key: "fallback#\(directory.path)") {
            SkinThumbnail.fallbackArtwork(in: directory)
        }
    }

    private func cachedImage(named: String?, in directory: URL) -> NSImage? {
        guard let named, !named.isEmpty else { return nil }
        return heroImage(key: directory.appendingPathComponent(named).path) {
            SkinThumbnail.loadImage(named: named, in: directory)
        }
    }

    private func heroImage(key: String, load: () -> NSImage?) -> NSImage? {
        if let cached = heroImages.object(forKey: key as NSString) { return cached }
        if let missedAt = heroMisses[key], now().timeIntervalSince(missedAt) < missRetryInterval {
            return nil
        }
        guard let image = load() else {
            heroMisses[key] = now()
            return nil
        }
        heroMisses[key] = nil
        heroImages.setObject(image, forKey: key as NSString)
        return image
    }
}

/// One gallery preview; views observe its `image`.
@MainActor
@Observable
private final class PreviewEntry {
    fileprivate(set) var image: NSImage?
    @ObservationIgnored var isRendering = false
    @ObservationIgnored var missedAt: Date?
    @ObservationIgnored var lastUse: UInt64 = 0
    @ObservationIgnored var cost = 0
    @ObservationIgnored var waiters: [CheckedContinuation<NSImage?, Never>] = []
}

/// One frame's side-button split; views observe its `art`.
@MainActor
@Observable
private final class ButtonArtEntry {
    fileprivate(set) var art: LiveButtonArt?
    @ObservationIgnored var isBuilding = false
    @ObservationIgnored var isFinished = false
    @ObservationIgnored var waiters: [CheckedContinuation<LiveButtonArt?, Never>] = []
}

/// The raw image layers of one skin variant, for live compositing.
struct SkinArtwork {
    let background: NSImage?
    let mask: NSImage?
    let overlay: NSImage?
}

/// A Pixel skin's frame split for its movable side buttons, as the live
/// stage draws it while a button is out of its place
/// (`HardwareButtonsLayer`): the Kit's split (`SkinButtonArt.make`: one
/// scan and one split of the installed artwork, never stored) plus the
/// pieces the stage moves, each also darkened for a held key
/// (`MotionMetrics.chromePressTint`).
///
/// Every piece is drawn so that, resampled apart at the stage's fractional
/// scale, the pieces still cover what the artwork drawn whole covers. Two
/// images that meet inside one screen pixel each cover only their share of
/// it, and composited they let the stage through (the W1 seam). The
/// filter still sees each piece on its own, which on a 1x display puts a
/// button up to 46 levels off the artwork drawn whole (88 around the open
/// fold's), so the stage draws the artwork whole whenever every button
/// rests and hands back to it with a cross-fade
/// (`HardwareButtonsState.drawsSplit`, `restFade`):
///
/// - a button group (power; the rocker's two halves) is one image while its
///   keys are level, so the rocker's halves never meet inside a pixel at
///   rest or on hover;
/// - where a sprite meets the body's edge, a seam fill lies under both: the
///   sprite's innermost column repeated `seamUnderBody` pixels under the
///   body and `seamUnderSprite` under the sprite, each pixel scaled by the
///   cover of the image over it, so it fills the pixel the two share and
///   adds nothing where either lets the stage through;
/// - a rolled-out sprite's gap is filled by its stem (the plan's stem): the
///   innermost column stretched from the body's edge to `seamUnderSprite`
///   pixels under the sprite.
struct LiveButtonArt: @unchecked Sendable {
    /// One movable image: `sprite` at `rect` (artwork pixels, top-left) at
    /// rest, with its seam fill and its stem strip.
    struct Piece: @unchecked Sendable {
        let sprite: CGImage
        /// `seamUnderBody + seamUnderSprite` wide, drawn from
        /// `seamUnderBody` left of `rect`.
        let seam: CGImage
        /// `stemStripWidth` identical columns, stretched across the gap.
        let stem: CGImage
        let rect: CGRect
    }

    /// The stem strip's width; its columns are identical, so it stretches
    /// to any gap without changing.
    static let stemStripWidth = 8
    /// How far the seam fill reaches under the body's edge: the filter's
    /// reach at the main stage's fit on a 1x display (≈3.5 artwork pixels
    /// per screen pixel) and more.
    static let seamUnderBody = 8
    /// How far the seam fill and the stem reach under the sprite: past the
    /// filter's reach at the stage's fit, inside every accepted button's
    /// 4 px or more of depth.
    static let seamUnderSprite = 3
    /// The seam fill's whole width.
    static var seamWidth: Int { seamUnderBody + seamUnderSprite }

    let art: SkinButtonArt
    /// `art.base` as the stage draws it, in the artwork's place while a
    /// button is out of its own.
    let background: NSImage
    /// The artwork's pixel size.
    let pixelSize: CGSize
    /// Each key's own piece, plain.
    let keys: [HardwareKey: Piece]
    /// Each key's own piece, darkened.
    let darkKeys: [HardwareKey: Piece]
    /// Each group's keys joined into one piece, for each set of its keys
    /// drawn darkened.
    let groups: [Int: [Set<HardwareKey>: Piece]]

    var buttons: [SkinHardwareButton] { art.buttons }

    /// The group `key` belongs to, nil for a key without a button.
    func group(of key: HardwareKey) -> Int? {
        buttons.first { $0.key == key }?.group
    }

    /// The keys of `group`, top to bottom.
    func keys(in group: Int) -> [HardwareKey] {
        buttons.filter { $0.group == group }.sorted { $0.rect.minY < $1.rect.minY }.map(\.key)
    }

    /// Scans and splits the frame at `artworkURL` (`SkinButtonScanner`,
    /// `SkinButtonArt.make`); nil when it has no buttons. Safe off the main
    /// thread.
    static func make(artworkURL: URL) -> LiveButtonArt? {
        let buttons = SkinButtonScanner.scan(artworkURL: artworkURL)
        guard !buttons.isEmpty, let art = SkinButtonArt.make(artworkURL: artworkURL, buttons: buttons) else {
            return nil
        }
        return make(art: art)
    }

    /// The pieces of `art`; nil when one cannot be drawn.
    static func make(art: SkinButtonArt) -> LiveButtonArt? {
        var keys: [HardwareKey: Piece] = [:]
        var darkKeys: [HardwareKey: Piece] = [:]
        for button in art.buttons {
            guard let sprite = art.sprites[button.key],
                  let stem = art.stems[button.key],
                  let rect = art.spriteRects[button.key],
                  let plain = piece(sprite: sprite, stem: stem, rect: rect, base: art.base),
                  let dark = plain.darkened()
            else {
                return nil
            }
            keys[button.key] = plain
            darkKeys[button.key] = dark
        }
        var groups: [Int: [Set<HardwareKey>: Piece]] = [:]
        for group in Set(art.buttons.map(\.group)) {
            let members = art.buttons.filter { $0.group == group }.map(\.key)
            var joined: [Set<HardwareKey>: Piece] = [:]
            // Every set of the group's keys that can be held at once.
            for mask in 0..<(1 << members.count) {
                let held = Set(members.indices.filter { mask & (1 << $0) != 0 }.map { members[$0] })
                let pieces = members.compactMap { held.contains($0) ? darkKeys[$0] : keys[$0] }
                guard pieces.count == members.count, let piece = join(pieces) else { return nil }
                joined[held] = piece
            }
            groups[group] = joined
        }
        return LiveButtonArt(
            art: art,
            background: NSImage(cgImage: art.base, size: .zero),
            pixelSize: CGSize(width: art.base.width, height: art.base.height),
            keys: keys,
            darkKeys: darkKeys,
            groups: groups
        )
    }

    /// A key's piece: its sprite, and its seam fill and stem strip built
    /// from `stem` (the sprite's innermost column) against `base` (the frame
    /// without the buttons) and the sprite, whose cover the fill follows.
    private static func piece(sprite: CGImage, stem: CGImage, rect: CGRect, base: CGImage) -> Piece? {
        let rows = Int(rect.height)
        let left = Int(rect.minX)
        guard rows > 0, left >= seamUnderBody, sprite.width >= seamUnderSprite,
              let column = pixels(of: stem), column.count == rows * 4,
              let body = base.cropping(to: CGRect(x: left - seamUnderBody, y: Int(rect.minY), width: seamUnderBody, height: rows)),
              let underBody = pixels(of: body), underBody.count == rows * seamUnderBody * 4,
              let spritePixels = pixels(of: sprite), spritePixels.count == rows * sprite.width * 4
        else {
            return nil
        }
        var seam = [UInt8](repeating: 0, count: rows * seamWidth * 4)
        var strip = [UInt8](repeating: 0, count: rows * stemStripWidth * 4)
        for row in 0..<rows {
            let pixel = Array(column[(row * 4)..<(row * 4 + 4)])
            // Scaled by the cover of what lies over it: all of it under the
            // opaque body and button, where it only shows in the pixel
            // their edges share; less under anti-aliased pixels, whose
            // see-through share the artwork keeps.
            for x in 0..<seamWidth {
                let cover = x < seamUnderBody
                    ? underBody[(row * seamUnderBody + x) * 4 + 3]
                    : spritePixels[(row * sprite.width + x - seamUnderBody) * 4 + 3]
                let offset = (row * seamWidth + x) * 4
                for channel in 0..<4 {
                    seam[offset + channel] = UInt8((Double(pixel[channel]) * Double(cover) / 255).rounded())
                }
            }
            for x in 0..<stemStripWidth {
                let offset = (row * stemStripWidth + x) * 4
                strip.replaceSubrange(offset..<(offset + 4), with: pixel)
            }
        }
        guard let seamImage = image(seam, width: seamWidth, height: rows),
              let stripImage = image(strip, width: stemStripWidth, height: rows)
        else {
            return nil
        }
        return Piece(sprite: sprite, seam: seamImage, stem: stripImage, rect: rect)
    }

    /// Several pieces at their rest places (they share no row) as one,
    /// pixel for pixel.
    private static func join(_ pieces: [Piece]) -> Piece? {
        guard let first = pieces.first else { return nil }
        if pieces.count == 1 { return first }
        let union = pieces.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        func joined(_ image: (Piece) -> CGImage, width: Int) -> CGImage? {
            draw(width: width, height: Int(union.height)) { context in
                for piece in pieces {
                    let image = image(piece)
                    // Top-left artwork rows into CoreGraphics' y-up space.
                    context.draw(image, in: CGRect(
                        x: 0,
                        y: union.maxY - piece.rect.maxY,
                        width: CGFloat(image.width),
                        height: piece.rect.height
                    ))
                }
            }
        }
        guard union.minX == pieces.map(\.rect.minX).min(), pieces.allSatisfy({ $0.rect.minX == union.minX }),
              let sprite = joined({ $0.sprite }, width: Int(union.width)),
              let seam = joined({ $0.seam }, width: seamWidth),
              let stem = joined({ $0.stem }, width: stemStripWidth)
        else {
            return nil
        }
        return Piece(sprite: sprite, seam: seam, stem: stem, rect: union)
    }

    /// `image`'s premultiplied sRGB RGBA bytes, top row first.
    private static func pixels(of image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Premultiplied sRGB RGBA bytes, top row first, as an image.
    fileprivate static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, bytes.count == width * height * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
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

    /// A premultiplied sRGB RGBA image of `width` × `height` drawn by `body`
    /// without interpolation, the Kit split's format: whole images drawn at
    /// whole pixels keep their bytes.
    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        body(context)
        return context.makeImage()
    }

    /// `image` with its colour multiplied by `factor` (premultiplied, so the
    /// alpha and the coverage stay as they are).
    fileprivate static func darkened(_ image: CGImage, by factor: Double) -> CGImage? {
        guard var bytes = pixels(of: image) else { return nil }
        for index in bytes.indices where index % 4 != 3 {
            bytes[index] = UInt8((Double(bytes[index]) * factor).rounded())
        }
        return self.image(bytes, width: image.width, height: image.height)
    }
}

private extension LiveButtonArt.Piece {
    /// The piece as a held key draws it: every image darkened by
    /// `MotionMetrics.chromePressTint`, 8 % in sRGB levels, DH's pressed
    /// step.
    func darkened() -> LiveButtonArt.Piece? {
        let factor = MotionMetrics.chromePressTint
        guard let sprite = LiveButtonArt.darkened(sprite, by: factor),
              let seam = LiveButtonArt.darkened(seam, by: factor),
              let stem = LiveButtonArt.darkened(stem, by: factor)
        else {
            return nil
        }
        return LiveButtonArt.Piece(sprite: sprite, seam: seam, stem: stem, rect: rect)
    }
}

extension RGBA {
    /// `color`'s sRGB components, the space a composition's colours are in.
    init(sRGB color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        self.init(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent)
        )
    }

    /// The colour to fill with: sRGB, never the Generic RGB of the Kit's
    /// annotation colour.
    var sRGBColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension NSImage {
    /// The pixel size of the image's largest bitmap representation: the
    /// artwork's natural size, which places it
    /// (`SkinDisplay.artworkRect(pixelSize:)`). `size` is in points, which a
    /// PNG's resolution metadata can make half the pixels.
    var artworkPixelSize: CGSize {
        if let largest = representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
           largest.pixelsWide > 0, largest.pixelsHigh > 0
        {
            return CGSize(width: largest.pixelsWide, height: largest.pixelsHigh)
        }
        return size
    }
}
