import CoreGraphics
import Foundation

/// One orientation of a skin `layout` file: where the device screen sits
/// inside the frame artwork and which image files make up the frame.
public struct SkinDisplay: Sendable, Hashable {
    public enum Orientation: String, Sendable {
        case portrait
        case landscape
    }

    /// Display size in skin pixels.
    public let displaySize: CGSize
    /// Device origin inside the layout artwork, top-left based like the file.
    public let origin: CGPoint
    /// Full artwork size in skin pixels.
    public let layoutSize: CGSize
    public let backgroundImage: String?
    public let maskImage: String?
    /// Legacy top overlay (`onion { image }`, e.g. `port_fore.webp`).
    public let overlayImage: String?
    public let orientation: Orientation
    /// Display corner radius in skin pixels (`corner_radius` in the device's
    /// display part); nil when the skin does not declare one.
    public let cornerRadius: CGFloat?
    /// Where the artwork part is placed in the layout (top-left based, like
    /// the file). Zero for every phone skin; the Wear rect and square skins
    /// inset their artwork by 16 and 18.
    public let artworkOrigin: CGPoint
    /// Whether the artwork's foreground declares a camera cutout
    /// (`cutout hole`): the foreground mask then draws the hole, which the
    /// live stage keeps above the video.
    public let declaresCutout: Bool

    public init(
        displaySize: CGSize,
        origin: CGPoint,
        layoutSize: CGSize,
        backgroundImage: String?,
        maskImage: String?,
        overlayImage: String? = nil,
        orientation: Orientation,
        cornerRadius: CGFloat? = nil,
        artworkOrigin: CGPoint = .zero,
        declaresCutout: Bool = false
    ) {
        self.displaySize = displaySize
        self.origin = origin
        self.layoutSize = layoutSize
        self.backgroundImage = backgroundImage
        self.maskImage = maskImage
        self.overlayImage = overlayImage
        self.orientation = orientation
        self.cornerRadius = cornerRadius
        self.artworkOrigin = artworkOrigin
        self.declaresCutout = declaresCutout
    }

    /// Screen rectangle in layout coordinates (top-left origin).
    public var screenRect: CGRect {
        CGRect(origin: origin, size: displaySize)
    }

    /// Artwork pixels per layout unit for background artwork of `pixelSize`
    /// (the file's full size). The emulator sizes a skin image's part from
    /// the image itself (`skin_background_init_from` in `skin/file.c`), so
    /// SDK artwork maps one pixel to one layout unit even where its size
    /// misses the layout's by a few pixels. Only artwork exported at another
    /// scale (width off by more than a quarter, a 2x re-export) is mapped at
    /// its width ratio.
    public func artworkScale(pixelSize: CGSize) -> CGFloat {
        guard layoutSize.width > 0, pixelSize.width > 0 else { return 1 }
        let ratio = pixelSize.width / layoutSize.width
        return (0.8...1.25).contains(ratio) ? 1 : ratio
    }

    /// Where background artwork of `pixelSize` is drawn, in layout
    /// coordinates (top-left based): at `artworkOrigin`, at its natural size.
    /// The rect can overhang or fall short of the layout box, which stays
    /// the frame and clips the overhang.
    ///
    /// Stretching the artwork to the layout box instead moves its
    /// transparent screen opening off the display rect: by 57 px at the
    /// bottom of `pixel_10_pro_fold/closed` (1236x2495 artwork in a 1236x2554
    /// layout) and by 3–17 px on six other SDK variants. Drawn this way,
    /// every installed skin with a rectangular opening has it exactly on its
    /// display rect.
    public func artworkRect(pixelSize: CGSize) -> CGRect {
        let scale = artworkScale(pixelSize: pixelSize)
        return CGRect(
            x: artworkOrigin.x,
            y: artworkOrigin.y,
            width: pixelSize.width / scale,
            height: pixelSize.height / scale
        )
    }

    /// Screen rectangle normalized to the layout size (0...1, top-left
    /// origin). Drives the live hero: the video and mask are placed with
    /// these fractions inside the scaled frame artwork.
    public var normalizedScreenRect: CGRect {
        guard layoutSize.width > 0, layoutSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: origin.x / layoutSize.width,
            y: origin.y / layoutSize.height,
            width: displaySize.width / layoutSize.width,
            height: displaySize.height / layoutSize.height
        )
    }
}

/// Scaled hero geometry: the full frame artwork fitted into the available
/// space, with the live video rect inside it (both top-left based).
public struct SkinHeroLayout: Sendable, Hashable {
    public let frame: CGRect
    public let screen: CGRect
    public let scale: CGFloat
    /// The skin's declared display corner radius in hero points
    /// (`corner_radius` × `scale`); 0 when the skin declares none. The live
    /// stage clips its video to `ScreenCornerPolicy`'s corner instead, which
    /// prefers the device's own radius and falls back to this one.
    public let screenCornerRadius: CGFloat
    /// Artwork rotation in degrees (SwiftUI `rotationEffect`), so the frame
    /// follows the device pose. The video itself stays unrotated: the stream
    /// is already composed for the pose.
    public let angle: CGFloat

    public init(
        frame: CGRect,
        screen: CGRect,
        scale: CGFloat,
        screenCornerRadius: CGFloat = 0,
        angle: CGFloat = 0
    ) {
        self.frame = frame
        self.screen = screen
        self.scale = scale
        self.screenCornerRadius = screenCornerRadius
        self.angle = angle
    }

    /// Fits the skin frame into `available`, preserving aspect ratio. The
    /// scale is capped at 1 so artwork is never upscaled into a blur.
    ///
    /// `rotation` is the stream's quarter-turn count (0...3, same convention
    /// as `TouchMapping`: 1 is counter-clockwise). The frame and screen rects
    /// are posed accordingly; artwork views rotate by `angle` around their
    /// center to match.
    public static func fit(
        display: SkinDisplay,
        available: CGSize,
        rotation: Int = 0
    ) -> SkinHeroLayout {
        let layout = display.layoutSize
        let turns = ((rotation % 4) + 4) % 4
        // Quarter turns transpose the frame; scale the posed size into the box.
        let posed = turns % 2 == 1
            ? CGSize(width: layout.height, height: layout.width)
            : layout
        let scale = min(
            available.width / max(posed.width, 1),
            available.height / max(posed.height, 1),
            1.0
        )
        let unrotated = native(display: display, scale: scale)
        var frame = unrotated.frame
        var screen = unrotated.screen

        if turns == 1 {
            // Counter-clockwise: (x, y) -> (y, W - x); rect gains the size swap.
            screen = CGRect(
                x: screen.minY,
                y: frame.width - screen.minX - screen.width,
                width: screen.height,
                height: screen.width
            )
            frame = CGRect(x: 0, y: 0, width: frame.height, height: frame.width)
        } else if turns == 3 {
            // Clockwise: (x, y) -> (H - y, x).
            screen = CGRect(
                x: frame.height - screen.minY - screen.height,
                y: screen.minX,
                width: screen.height,
                height: screen.width
            )
            frame = CGRect(x: 0, y: 0, width: frame.height, height: frame.width)
        } else if turns == 2 {
            screen = CGRect(
                x: frame.width - screen.minX - screen.width,
                y: frame.height - screen.minY - screen.height,
                width: screen.width,
                height: screen.height
            )
        }
        return SkinHeroLayout(
            frame: frame,
            screen: screen,
            scale: scale,
            screenCornerRadius: unrotated.screenCornerRadius,
            angle: CGFloat(-90 * turns)
        )
    }

    /// The skin in its native (unrotated) orientation at `scale` points per
    /// layout unit. The live stage lays the device out this way at the fit
    /// of the pose it rests in (`PoseFit`) and turns the whole composition
    /// with one wrapper, so a portrait device at rest in landscape is laid
    /// out at its landscape size instead of being enlarged into it.
    public static func native(display: SkinDisplay, scale: CGFloat) -> SkinHeroLayout {
        let layout = display.layoutSize
        let frame = CGRect(
            x: 0,
            y: 0,
            width: max(layout.width * scale, 1),
            height: max(layout.height * scale, 1)
        )
        let normalized = display.normalizedScreenRect
        let screen = CGRect(
            x: frame.width * normalized.minX,
            y: frame.height * normalized.minY,
            width: max(frame.width * normalized.width, 1),
            height: max(frame.height * normalized.height, 1)
        )
        return SkinHeroLayout(
            frame: frame,
            screen: screen,
            scale: scale,
            screenCornerRadius: display.cornerRadius.map { $0 * scale } ?? 0
        )
    }
}

/// The parsed orientations of one `layout` file. Modern phone skins carry a
/// single portrait (or landscape, for tablets) section; legacy skins carry both.
public struct SkinLayoutFile: Sendable, Hashable {
    public let portrait: SkinDisplay?
    public let landscape: SkinDisplay?

    public init(portrait: SkinDisplay?, landscape: SkinDisplay?) {
        self.portrait = portrait
        self.landscape = landscape
    }

    public var preferred: SkinDisplay? { portrait ?? landscape }
}

/// Parses the emulator skin `layout` text format (`parts` + `layouts`
/// sections). Unknown keys, events and extra parts (buttons, LEDs) are
/// ignored; only the display size, the artwork images and the device and
/// artwork placements are kept.
public enum SkinLayout {
    public static func parseFile(at url: URL) -> SkinLayoutFile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> SkinLayoutFile {
        var displayWidth: CGFloat?
        var displayHeight: CGFloat?
        var displayCornerRadius: CGFloat?
        var artwork: [String: Artwork] = [:]
        var layouts: [String: LayoutSection] = [:]

        var stack: [String] = []
        // A `partN` block inside a layout section names a part and its offset.
        var placementLayout: String?
        var placementName: String?
        var placementX: CGFloat?
        var placementY: CGFloat?

        func closeBlock() {
            if let layout = placementLayout, stack.last?.hasPrefix("part") == true {
                if let name = placementName {
                    var section = layouts[layout] ?? LayoutSection()
                    section.placements.append(
                        Placement(name: name, x: placementX ?? 0, y: placementY ?? 0)
                    )
                    layouts[layout] = section
                }
                placementLayout = nil
                placementName = nil
                placementX = nil
                placementY = nil
            }
            _ = stack.popLast()
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line == "}" {
                closeBlock()
                continue
            }

            if line.hasSuffix("{") {
                let name = line.dropLast().trimmingCharacters(in: .whitespaces)
                stack.append(String(name))
                if stack.count == 3, stack[0] == "layouts", stack[2].hasPrefix("part") {
                    placementLayout = stack[1]
                    placementName = nil
                    placementX = nil
                    placementY = nil
                }
                continue
            }

            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 2 else { continue }
            let key = tokens[0]
            let value = tokens[1]

            if placementLayout != nil, stack.count == 3, stack[0] == "layouts" {
                switch key {
                case "name": placementName = value
                case "x": placementX = number(value)
                case "y": placementY = number(value)
                default: break
                }
                continue
            }

            guard stack.count == 3, stack[0] == "parts" else {
                if stack.count == 2, stack[0] == "layouts" {
                    var section = layouts[stack[1]] ?? LayoutSection()
                    if key == "width" { section.width = number(value) ?? 0 }
                    if key == "height" { section.height = number(value) ?? 0 }
                    layouts[stack[1]] = section
                }
                continue
            }

            if stack[1] == "device", stack[2] == "display" {
                if key == "width" { displayWidth = number(value) }
                if key == "height" { displayHeight = number(value) }
                if key == "corner_radius" { displayCornerRadius = number(value) }
            } else if stack[2] == "foreground", key == "cutout" {
                artwork[stack[1], default: Artwork()].declaresCutout = true
            } else if stack[2] == "background", key == "image" {
                artwork[stack[1], default: Artwork()].background = value
            } else if stack[2] == "foreground", key == "mask" {
                artwork[stack[1], default: Artwork()].mask = value
            } else if stack[2] == "onion", key == "image" {
                artwork[stack[1], default: Artwork()].overlay = value
            }
        }

        func display(for orientationName: String) -> SkinDisplay? {
            guard
                let section = layouts[orientationName],
                section.width > 0, section.height > 0,
                let width = displayWidth, width > 0,
                let height = displayHeight, height > 0,
                let device = section.placements.first(where: { $0.name == "device" })
            else {
                return nil
            }
            let artPlacement = section.placements.first(where: { $0.name != "device" })
            let art = artPlacement.flatMap { artwork[$0.name] }
            return SkinDisplay(
                displaySize: CGSize(width: width, height: height),
                origin: CGPoint(x: device.x, y: device.y),
                layoutSize: CGSize(width: section.width, height: section.height),
                backgroundImage: art?.background,
                maskImage: art?.mask,
                overlayImage: art?.overlay,
                orientation: orientationName == "landscape" ? .landscape : .portrait,
                cornerRadius: displayCornerRadius,
                artworkOrigin: CGPoint(x: artPlacement?.x ?? 0, y: artPlacement?.y ?? 0),
                declaresCutout: art?.declaresCutout ?? false
            )
        }

        return SkinLayoutFile(
            portrait: display(for: "portrait"),
            landscape: display(for: "landscape")
        )
    }

    private static func number(_ text: String) -> CGFloat? {
        Double(text).map { CGFloat($0) }
    }

    private struct Artwork {
        var background: String?
        var mask: String?
        var overlay: String?
        var declaresCutout = false
    }

    private struct LayoutSection {
        var width: CGFloat = 0
        var height: CGFloat = 0
        var placements: [Placement] = []
    }

    private struct Placement {
        let name: String
        let x: CGFloat
        let y: CGFloat
    }
}
