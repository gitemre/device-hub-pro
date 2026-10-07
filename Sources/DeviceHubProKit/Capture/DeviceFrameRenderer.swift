import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One skin artwork plus the screen rectangle to composite a screenshot into.
/// `displayRect` is in artwork pixel coordinates, top-left based like the skin
/// `layout` file; `cornerRadius` is in the same pixels.
public struct DeviceFrameSpec: Sendable, Hashable {
    public let artwork: URL
    public let displayRect: CGRect
    public let cornerRadius: CGFloat?
    /// The device's camera cutout, mapped into `displayRect` and filled black
    /// over the screenshot (a capture carries none); nil draws none.
    public let cutout: CutoutPlacement?
    /// Quarter turns counter-clockwise the artwork is turned by before the
    /// screenshot goes in (`Surface.ROTATION_*`, as the live stage turns the
    /// device): a capture taken in a pose the skin has no display for is
    /// framed in its natural display, turned. The canvas is the turned
    /// artwork, `displayRect` (in the unturned artwork) turns with it, and
    /// the screenshot and `cutout` are drawn as posed, into the turned rect.
    public let quarterTurns: Int

    public init(
        artwork: URL,
        displayRect: CGRect,
        cornerRadius: CGFloat? = nil,
        cutout: CutoutPlacement? = nil,
        quarterTurns: Int = 0
    ) {
        self.artwork = artwork
        self.displayRect = displayRect
        self.cornerRadius = cornerRadius
        self.cutout = cutout
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
    }

    /// `displayRect` in the turned canvas (top-left based), for an artwork
    /// of `artworkSize` pixels.
    public func turnedDisplayRect(artworkSize: CGSize) -> CGRect {
        guard quarterTurns != 0 else { return displayRect }
        return displayRect
            .applying(AppleChromeLayout.turn(canvas: artworkSize, quarterTurns: quarterTurns))
            .standardized
    }
}

extension DeviceFrameSpec {
    /// This spec with the artwork turned `quarterTurns` more.
    func turned(by quarterTurns: Int) -> DeviceFrameSpec {
        DeviceFrameSpec(
            artwork: artwork,
            displayRect: displayRect,
            cornerRadius: cornerRadius,
            cutout: cutout,
            quarterTurns: self.quarterTurns + quarterTurns
        )
    }
}

/// Failures the device-frame renderer can report.
public enum DeviceFrameError: Error, Equatable, CustomStringConvertible {
    case artworkMissing
    case artworkDecodeFailed
    case imageDecodeFailed
    case contextCreationFailed
    case encodingFailed

    public var description: String {
        switch self {
        case .artworkMissing:
            return "The device's skin artwork is unavailable."
        case .artworkDecodeFailed:
            return "The skin artwork could not be decoded as an image."
        case .imageDecodeFailed:
            return "The screenshot could not be decoded as an image."
        case .contextCreationFailed:
            return "The device-frame canvas could not be created."
        case .encodingFailed:
            return "The framed screenshot could not be encoded as PNG."
        }
    }
}

/// Composites a raw screenshot into a device skin's frame artwork: the
/// artwork is the canvas, and the screenshot is aspect-filled (scaled up to
/// cover, centre-cropped) into the display rectangle, optionally clipped to a
/// rounded rect, with the device's camera cutout filled black over it. Output
/// size is the artwork's pixel size. A device without a skin is framed in the
/// vector body its `DeviceComposition` plans instead
/// (``compose(screenshot:composition:)``). Pure CoreGraphics, no UI
/// frameworks.
///
/// A composite decodes a multi-megapixel artwork, draws the full-size canvas
/// and encodes a PNG (~100–300 ms). UI callers use the `…InBackground`
/// variants, which run that work off the caller's actor; decoded artworks are
/// kept in a small cache (keyed by file and modification date) so consecutive
/// framed captures decode the artwork once.
public enum DeviceFrameRenderer {
    /// Decides the screen's clip radius, in the display's layout units, for
    /// the variant and display a capture of `frame` pixels is framed in; nil
    /// keeps the skin's declared `corner_radius`. The app answers with the
    /// radius its live stage clips the same display to
    /// (`ScreenCornerPolicy`), which needs the artwork's measured opening and
    /// the device's reported corners — neither of which this renderer has.
    public typealias ScreenCornerResolver = @Sendable (
        _ variant: SkinVariant,
        _ display: SkinDisplay,
        _ frame: CGSize
    ) async -> CGFloat?

    /// ``ScreenCornerResolver`` plus the camera cutout to fill black on the
    /// display (nil: none), placed for the capture's orientation. The app
    /// answers with the cutout the device reports for the panel the capture
    /// shows (`DisplayShape`), which this renderer does not know either.
    public typealias ScreenShapeResolver = @Sendable (
        _ variant: SkinVariant,
        _ display: SkinDisplay,
        _ frame: CGSize
    ) async -> (radius: CGFloat?, cutout: CutoutPlacement?)

    /// ``compose(screenshot:skin:)`` on a background task, so a `@MainActor`
    /// caller never spends the decode/draw/encode time on the main thread.
    /// `screenCorner` overrides the skin's corner radius (see
    /// ``ScreenCornerResolver``).
    public static func composeInBackground(
        screenshot: Data,
        skin: ResolvedSkin,
        screenCorner: ScreenCornerResolver? = nil
    ) async throws -> Data {
        var resolvingShape: ScreenShapeResolver?
        if let screenCorner {
            resolvingShape = { variant, display, frame in
                (radius: await screenCorner(variant, display, frame), cutout: nil)
            }
        }
        return try await composeInBackground(screenshot: screenshot, skin: skin, resolvingShape: resolvingShape)
    }

    /// ``compose(screenshot:skin:)`` on a background task, with the screen's
    /// corner and camera cutout from `screenShape` (see
    /// ``ScreenShapeResolver``).
    ///
    /// `quarterTurns` is the display rotation the capture was taken at
    /// (`Surface.ROTATION_*`), for a skin with no display in the capture's
    /// pose (see ``compose(screenshot:skin:quarterTurns:)``).
    public static func composeInBackground(
        screenshot: Data,
        skin: ResolvedSkin,
        quarterTurns: Int? = nil,
        screenShape: @escaping ScreenShapeResolver
    ) async throws -> Data {
        try await composeInBackground(
            screenshot: screenshot,
            skin: skin,
            quarterTurns: quarterTurns,
            resolvingShape: screenShape
        )
    }

    private static func composeInBackground(
        screenshot: Data,
        skin: ResolvedSkin,
        quarterTurns: Int? = nil,
        resolvingShape: ScreenShapeResolver?
    ) async throws -> Data {
        guard let resolvingShape else {
            return try await Task.detached(priority: .userInitiated) {
                try compose(screenshot: screenshot, skin: skin, quarterTurns: quarterTurns)
            }.value
        }
        let target = try await Task.detached(priority: .userInitiated) {
            try frameTarget(screenshot: screenshot, skin: skin, quarterTurns: quarterTurns)
        }.value
        let shape = await resolvingShape(target.variant, target.display, target.frame)
        let resolved = try shape.radius.map { radius in
            guard let spec = spec(for: target.variant, display: target.display, cornerRadius: radius) else {
                throw DeviceFrameError.artworkMissing
            }
            return spec
        } ?? target.spec
        let spec = DeviceFrameSpec(
            artwork: resolved.artwork,
            displayRect: resolved.displayRect,
            cornerRadius: resolved.cornerRadius,
            cutout: shape.cutout,
            quarterTurns: target.spec.quarterTurns
        )
        return try await Task.detached(priority: .userInitiated) {
            try compose(screenshot: screenshot, spec: spec)
        }.value
    }

    /// Resolves `avdName`'s skin — `skinsDirectory` defaults to
    /// `SkinLocator.skinsDirectory()` — and composites, all on a background
    /// task (the resolution reads `config.ini` and the layout files). Returns
    /// nil when the AVD has no resolvable skin, so the caller keeps the raw
    /// shot; throws ``DeviceFrameError`` when compositing fails.
    /// `screenCorner` overrides the skin's corner radius (see
    /// ``ScreenCornerResolver``).
    public static func composeInBackground(
        screenshot: Data,
        avdName: String,
        skinsDirectory: URL? = nil,
        avdHome: URL? = nil,
        screenCorner: ScreenCornerResolver? = nil
    ) async throws -> Data? {
        guard let skin = await resolveSkin(avdName: avdName, skinsDirectory: skinsDirectory, avdHome: avdHome) else {
            return nil
        }
        return try await composeInBackground(screenshot: screenshot, skin: skin, screenCorner: screenCorner)
    }

    /// The AVD-name composite with the screen's corner and camera cutout
    /// from `screenShape` (see ``ScreenShapeResolver``); nil when the AVD
    /// has no resolvable skin. `quarterTurns`: the capture's display
    /// rotation, when known (``compose(screenshot:skin:quarterTurns:)``).
    public static func composeInBackground(
        screenshot: Data,
        avdName: String,
        skinsDirectory: URL? = nil,
        avdHome: URL? = nil,
        quarterTurns: Int? = nil,
        screenShape: @escaping ScreenShapeResolver
    ) async throws -> Data? {
        guard let skin = await resolveSkin(avdName: avdName, skinsDirectory: skinsDirectory, avdHome: avdHome) else {
            return nil
        }
        return try await composeInBackground(
            screenshot: screenshot,
            skin: skin,
            quarterTurns: quarterTurns,
            screenShape: screenShape
        )
    }

    private static func resolveSkin(avdName: String, skinsDirectory: URL?, avdHome: URL?) async -> ResolvedSkin? {
        await Task.detached(priority: .userInitiated) {
            SkinResolver.resolve(
                avdName: avdName,
                skinsDirectory: skinsDirectory ?? SkinLocator.skinsDirectory(),
                avdHome: avdHome
            )
        }.value
    }

    /// ``compose(screenshot:composition:)`` on a background task.
    public static func composeInBackground(
        screenshot: Data,
        composition: DeviceComposition,
        screenshotTurns: Int = 0
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try compose(screenshot: screenshot, composition: composition, screenshotTurns: screenshotTurns)
        }.value
    }

    /// `image` turned `quarterTurns` counter-clockwise (a simulator's
    /// capture, posed by its interface, drawn in a chrome turned with the
    /// device: `AppleChromePose`); the image itself for no turn.
    static func turned(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let size = CGSize(width: image.width, height: image.height)
        let out = turns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(out.width),
                  height: Int(out.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // Top-left based: the turn of `AppleChromeLayout.turn`, drawn in a
        // y-down space.
        context.translateBy(x: 0, y: out.height)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(AppleChromeLayout.turn(canvas: size, quarterTurns: turns))
        // The image drawn upright in the y-down space.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    /// Frames a screenshot in a vector body (`DeviceCompositionPlanner.vector`,
    /// planned for the capture: its layout units are the capture's pixels),
    /// drawn by `DeviceCompositionRenderer` at one unit per pixel, so the
    /// output is ceil(`layoutSize`) pixels, transparent outside the body. The
    /// screenshot is aspect-filled into the screen rect like a skin's
    /// display, clipped to the screen's corner, with the cutout filled black
    /// over it.
    ///
    /// The plan's screen rect is unsnapped (a 3.3 mm bezel is 50.669 px at
    /// 390 dpi), so the shot is drawn from the whole pixel nearest the
    /// rect's origin: a capture of the screen's own size is then copied
    /// pixel for pixel rather than resampled soft by the fraction. The clip
    /// stays the plan's, so at most one edge pixel column or row shows a
    /// fraction of the glass under it.
    ///
    /// Throws `.imageDecodeFailed` for an undecodable screenshot and
    /// `.artworkMissing` for a skin plan (its artwork is not in the plan:
    /// frame those with a ``DeviceFrameSpec``).
    public static func compose(screenshot: Data, composition: DeviceComposition, screenshotTurns: Int = 0) throws -> Data {
        guard let decoded = decode(screenshot) else {
            throw DeviceFrameError.imageDecodeFailed
        }
        switch composition.body {
        case .vector, .appleChrome: break
        case .skin: throw DeviceFrameError.artworkMissing
        }
        guard let screen = turned(decoded, quarterTurns: screenshotTurns) else {
            throw DeviceFrameError.contextCreationFailed
        }
        let framed = DeviceCompositionRenderer.render(composition, pixelsPerUnit: 1) { context, rect in
            let fill = fillRect(for: screen, in: rect)
            context.draw(
                screen,
                in: CGRect(
                    x: fill.minX.rounded(),
                    y: fill.minY.rounded(),
                    width: fill.width,
                    height: fill.height
                )
            )
        }
        guard let framed else {
            throw DeviceFrameError.contextCreationFailed
        }
        return try pngData(from: framed)
    }

    /// An encoded screenshot's pixel size, read from its header without
    /// decoding it; nil when it is not an image.
    public static func pixelSize(ofScreenshot data: Data) -> CGSize? {
        pixelSize(of: data)
    }

    /// What a capture is framed in: the variant and display it matches, their
    /// spec with the skin's own corner radius, and the capture's pixel size
    /// (read from the image header, not decoded).
    private struct FrameTarget: Sendable {
        let variant: SkinVariant
        let display: SkinDisplay
        let spec: DeviceFrameSpec
        let frame: CGSize
    }

    private static func frameTarget(screenshot: Data, skin: ResolvedSkin, quarterTurns: Int?) throws -> FrameTarget {
        guard let frameSize = pixelSize(of: screenshot) else {
            throw DeviceFrameError.imageDecodeFailed
        }
        return try frameTarget(frameSize: frameSize, skin: skin, quarterTurns: quarterTurns)
    }

    private static func frameTarget(frameSize: CGSize, skin: ResolvedSkin, quarterTurns: Int?) throws -> FrameTarget {
        guard let variant = skin.variant(matching: frameSize) ?? skin.preferredVariant else {
            throw DeviceFrameError.artworkMissing
        }
        if let display = display(for: variant, matching: frameSize) {
            guard let spec = spec(for: variant, display: display) else { throw DeviceFrameError.artworkMissing }
            return FrameTarget(variant: variant, display: display, spec: spec, frame: frameSize)
        }
        // No display in the capture's pose (every modern skin in landscape,
        // the open fold's sole section): the display of the other pose,
        // turned the way the device is, when that turn is known and is one
        // that swaps the pose.
        let turns = quarterTurns.map { (($0 % 4) + 4) % 4 }
        guard let turns, turns % 2 == 1,
              let display = display(for: variant, matching: CGSize(width: frameSize.height, height: frameSize.width)),
              let upright = spec(for: variant, display: display)
        else {
            throw DeviceFrameError.artworkMissing
        }
        return FrameTarget(variant: variant, display: display, spec: upright.turned(by: turns), frame: frameSize)
    }

    /// Picks the skin variant whose display best matches the screenshot's
    /// aspect (foldables: open vs cover), then the display matching the
    /// capture's orientation (portrait/landscape), resolves its artwork, and
    /// composites. A skin with no display in the capture's pose frames it in
    /// the other pose's display with the artwork turned by `quarterTurns`,
    /// the capture's display rotation (`Surface.ROTATION_*`: 1 or 3 for a
    /// landscape capture of a portrait device), as the live stage turns it.
    /// Throws `.artworkMissing` when the skin has neither, the turn is not
    /// known (or does not swap the pose), or the artwork file is missing:
    /// callers keep the raw shot or fall back to a vector body.
    public static func compose(screenshot: Data, skin: ResolvedSkin, quarterTurns: Int? = nil) throws -> Data {
        guard let screen = decode(screenshot) else {
            throw DeviceFrameError.imageDecodeFailed
        }
        let frameSize = CGSize(width: screen.width, height: screen.height)
        let target = try frameTarget(frameSize: frameSize, skin: skin, quarterTurns: quarterTurns)
        return try compose(screen, spec: target.spec)
    }

    /// The variant's display for the capture's pose: the section keyed for
    /// that orientation first, then any section whose `displaySize` matches
    /// the pose. The scan recovers fold-open skins that name their sole
    /// portrait-shaped display section `landscape` (`pixel_*_pro_fold`).
    /// Nil when no display matches — legacy landscape sections carry
    /// `rotation` metadata the layout parser drops, so their display stays
    /// portrait-shaped and a landscape capture cannot use them.
    static func display(for variant: SkinVariant, matching frameSize: CGSize) -> SkinDisplay? {
        guard let layout = variant.layout else { return nil }
        let wantsLandscape = frameSize.width > frameSize.height
        let keyed = wantsLandscape ? layout.landscape : layout.portrait
        if let keyed, matchesPose(keyed, wantsLandscape: wantsLandscape) {
            return keyed
        }
        return [layout.portrait, layout.landscape]
            .compactMap { $0 }
            .first { matchesPose($0, wantsLandscape: wantsLandscape) }
    }

    private static func matchesPose(_ display: SkinDisplay, wantsLandscape: Bool) -> Bool {
        let size = display.displaySize
        guard size.width > 0, size.height > 0 else { return false }
        return wantsLandscape == (size.width > size.height)
    }

    /// The preferred variant's preferred (portrait-first) display, for callers
    /// with no capture to orient to; ``compose(screenshot:skin:)`` picks the
    /// display matching the capture's orientation instead. The display rect is
    /// mapped from layout pixels into the artwork the way the emulator draws
    /// it: at its natural size from the artwork part's origin
    /// (`SkinDisplay.artworkRect(pixelSize:)`), so SDK artwork a few pixels
    /// off its layout's size keeps its screen opening on the display rect; an
    /// artwork exported at another scale is still scaled uniformly. Returns
    /// nil when there is no layout, no background image, or the file is
    /// missing.
    ///
    /// `cornerRadius` is the skin's `corner_radius` at the same scale. The
    /// mask/overlay layers are still not composited.
    public static func spec(for skin: ResolvedSkin) -> DeviceFrameSpec? {
        guard let variant = skin.preferredVariant,
              let display = variant.layout?.preferred
        else {
            return nil
        }
        return spec(for: variant, display: display)
    }

    /// The spec with `cornerRadius` (layout units) in place of the skin's
    /// declared one, scaled to artwork pixels like the display rect; 0 clips
    /// square.
    static func spec(for variant: SkinVariant, display: SkinDisplay, cornerRadius: CGFloat) -> DeviceFrameSpec? {
        guard let declared = spec(for: variant, display: display) else { return nil }
        let scale = declared.displayRect.width / max(display.displaySize.width, 1)
        return DeviceFrameSpec(
            artwork: declared.artwork,
            displayRect: declared.displayRect,
            cornerRadius: cornerRadius * scale
        )
    }

    static func spec(for variant: SkinVariant, display: SkinDisplay) -> DeviceFrameSpec? {
        guard let background = display.backgroundImage,
              !background.isEmpty,
              let artworkSize = pixelSize(of: variant.directory.appendingPathComponent(background)),
              artworkSize.width > 0, artworkSize.height > 0,
              display.layoutSize.width > 0, display.layoutSize.height > 0
        else {
            return nil
        }
        let scale = display.artworkScale(pixelSize: artworkSize)
        let placement = display.artworkRect(pixelSize: artworkSize)
        let screen = display.screenRect
        return DeviceFrameSpec(
            artwork: variant.directory.appendingPathComponent(background),
            displayRect: CGRect(
                x: (screen.minX - placement.minX) * scale,
                y: (screen.minY - placement.minY) * scale,
                width: screen.width * scale,
                height: screen.height * scale
            ),
            cornerRadius: display.cornerRadius.map { $0 * scale }
        )
    }

    public static func compose(screenshot: Data, spec: DeviceFrameSpec) throws -> Data {
        guard let screen = decode(screenshot) else {
            throw DeviceFrameError.imageDecodeFailed
        }
        return try compose(screen, spec: spec)
    }

    private static func compose(_ screen: CGImage, spec: DeviceFrameSpec) throws -> Data {
        guard let artwork = ArtworkCache.shared.image(at: spec.artwork, decode: decodeArtwork) else {
            throw DeviceFrameError.artworkDecodeFailed
        }

        let artworkSize = CGSize(width: artwork.width, height: artwork.height)
        let turns = spec.quarterTurns
        let width = turns % 2 == 1 ? artwork.height : artwork.width
        let height = turns % 2 == 1 ? artwork.width : artwork.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DeviceFrameError.contextCreationFailed
        }
        context.interpolationQuality = .high

        context.saveGState()
        if turns != 0 {
            // The artwork turned as `turned(_:quarterTurns:)` turns an
            // image: in a y-down space the turn of
            // `AppleChromeLayout.turn`, whole pixels onto whole pixels.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.concatenate(AppleChromeLayout.turn(canvas: artworkSize, quarterTurns: turns))
            context.translateBy(x: 0, y: artworkSize.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(artwork, in: CGRect(origin: .zero, size: artworkSize))
        context.restoreGState()

        // The spec is top-left based like the layout file; CoreGraphics user
        // space is y-up, so the rect is flipped around the canvas height.
        let displayRect = spec.turnedDisplayRect(artworkSize: artworkSize)
        let rect = CGRect(
            x: displayRect.minX,
            y: CGFloat(height) - displayRect.maxY,
            width: displayRect.width,
            height: displayRect.height
        )
        context.saveGState()
        if let radius = spec.cornerRadius, radius > 0 {
            // CoreGraphics traps on a corner wider than half the rect.
            let corner = min(radius, rect.width / 2, rect.height / 2)
            context.addPath(
                CGPath(
                    roundedRect: rect,
                    cornerWidth: corner,
                    cornerHeight: corner,
                    transform: nil
                )
            )
            context.clip()
        } else {
            context.clip(to: rect)
        }
        context.draw(screen, in: fillRect(for: screen, in: rect))
        // The camera cutout over the shot, inside the clip: the capture
        // carries none, the device's glass does.
        if let cutout = spec.cutout?.path(in: displayRect) {
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
            if let flipped = cutout.copy(using: &flip) {
                context.addPath(flipped)
                context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                context.fillPath()
            }
        }
        context.restoreGState()

        guard let framed = context.makeImage() else {
            throw DeviceFrameError.contextCreationFailed
        }
        return try pngData(from: framed)
    }

    /// Aspect-fill placement: scale the screenshot to cover the display rect,
    /// centre it, and let the clip crop the overflow.
    private static func fillRect(for image: CGImage, in rect: CGRect) -> CGRect {
        let scale = max(
            rect.width / CGFloat(image.width),
            rect.height / CGFloat(image.height)
        )
        let size = CGSize(
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Decodes the artwork eagerly, so the cached image holds its pixels
    /// rather than re-decoding the file on every draw.
    private static func decodeArtwork(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        )
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Image pixel size without a full decode, for the resolution math.
    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(of: source)
    }

    /// An encoded screenshot's pixel size, from its header.
    private static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(of: source)
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw DeviceFrameError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DeviceFrameError.encodingFailed
        }
        return data as Data
    }
}

/// The most recently decoded skin artworks. An entry is keyed by the file's
/// path, modification date and size, so an artwork replaced on disk (an SDK
/// skin update) is decoded afresh. Two entries cover a foldable's open and
/// cover artworks; a decoded phone artwork is ~12 MB, so the cache stays
/// small on purpose.
private final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private struct Key: Hashable {
        let path: String
        let modified: Date?
        let size: Int?
    }

    private let capacity = 2
    private let lock = NSLock()
    private var entries: [(key: Key, image: CGImage)] = []

    func image(at url: URL, decode: (URL) -> CGImage?) -> CGImage? {
        // FileManager, not `URL.resourceValues`: an NSURL caches its resource
        // values, so a long-lived spec URL would keep reporting the old date.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = Key(
            path: url.standardizedFileURL.path,
            modified: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.intValue
        )
        lock.lock()
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.image
        }
        lock.unlock()

        guard let image = decode(url) else { return nil }
        lock.lock()
        entries.removeAll { $0.key.path == key.path }
        entries.append((key, image))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
        return image
    }
}
