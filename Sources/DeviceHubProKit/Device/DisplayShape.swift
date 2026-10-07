import CoreGraphics
import Foundation

/// A display's screen outline as the device itself reports it: the panel's
/// natural size, the radius of each rounded corner and the camera cutout,
/// read from one `DisplayDeviceInfo{…}` line of `adb shell dumpsys display`.
///
/// This is Android's equivalent of Device Hub's per-model screen mask, and it
/// covers every device, skin or not: the framework prints the
/// `RoundedCorners` (API 31+) and the raw cutout spec with the inputs its
/// parser needs (`CutoutPathParserInfo`, API 31+) for every display device.
/// A foldable lists one block per panel, so a frame's size picks the one on
/// screen (`matching(frame:in:)`). Screen captures and streams carry neither
/// the rounded corners nor the cutout, so the host has to draw both.
///
/// Not to be confused with the framework's own `DisplayShape{type=…}` in the
/// same dump, which only names a shape type and never carries a path.
public struct DisplayShape: Sendable, Hashable, Codable {
    /// One `RoundedCorner{position=…, radius=…, center=Point(x, y)}`: a
    /// quarter circle of `radius` display pixels around the center.
    public struct RoundedCorner: Sendable, Hashable, Codable {
        public var radius: Int
        public var centerX: Int
        public var centerY: Int

        public init(radius: Int, centerX: Int, centerY: Int) {
            self.radius = radius
            self.centerX = centerX
            self.centerY = centerY
        }
    }

    /// The display's cutout as `dumpsys` prints it
    /// (`cutoutPathParserInfo={CutoutPathParserInfo{…}}`): the raw spec and
    /// the inputs Android's `DisplayCutout.getCutoutPath` resolves it with.
    public struct Cutout: Sendable, Hashable, Codable {
        /// The spec verbatim (`cutoutSpec={…}`): SVG path data with AOSP's
        /// `@left`/`@right`/`@bottom`/`@dp`… markers, not yet resolved.
        public var spec: String
        /// dp → px factor for `@dp` (`density={2.4375}` is 390 dpi / 160).
        public var density: Double
        /// The full panel's size the spec is positioned in
        /// (`physicalDisplayWidth=`/`Height=`; `displayWidth=`/`Height=` on
        /// API 31–32, which print no physical size).
        public var physicalWidth: Int
        public var physicalHeight: Int
        /// The display mode's size over the full panel's (`1.0` unless a
        /// reduced-resolution mode is on; absent and 1 on API 31–32).
        public var physicalPixelDisplaySizeRatio: Double
        /// `scale={…}`: a compatibility scale, 1 for a display device.
        public var scale: Double

        public init(
            spec: String,
            density: Double,
            physicalWidth: Int,
            physicalHeight: Int,
            physicalPixelDisplaySizeRatio: Double = 1,
            scale: Double = 1
        ) {
            self.spec = spec
            self.density = density
            self.physicalWidth = physicalWidth
            self.physicalHeight = physicalHeight
            self.physicalPixelDisplaySizeRatio = physicalPixelDisplaySizeRatio
            self.scale = scale
        }

        /// The cutout outline in display pixels (natural orientation,
        /// top-left origin), resolved as the device resolves it
        /// (`CutoutSpecification`); nil when the spec does not parse. The
        /// `rotation={…}` the dump also prints is left out on purpose: it
        /// turns the outline into a rotated logical display's coordinates,
        /// and a display device's own cutout is always at rotation 0.
        public var path: CGPath? {
            guard let path = CutoutSpecification.path(
                spec: spec,
                density: CGFloat(density),
                physicalWidth: physicalWidth,
                physicalHeight: physicalHeight,
                physicalPixelDisplaySizeRatio: CGFloat(physicalPixelDisplaySizeRatio)
            ) else { return nil }
            guard scale != 1 else { return path }
            var transform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
            return path.copy(using: &transform)
        }
    }

    /// The framework's id for the display device (`local:<physical id>` for
    /// a built-in panel), stable across boots.
    public var uniqueId: String
    /// The device's name for it (`Built-in Screen`).
    public var name: String
    /// Pixels, in the display's natural orientation (`2076 x 2152`).
    public var width: Int
    public var height: Int
    /// `density 390`: the logical density in dpi; nil when not printed.
    public var densityDpi: Int?
    /// `390.0 x 390.0 dpi`: the panel's reported physical dpi. On an
    /// emulator this is `hw.lcd.density`, not the modelled phone's.
    public var xDpi: Double?
    public var yDpi: Double?
    /// `type INTERNAL`: a built-in panel (`EXTERNAL`, `VIRTUAL`, `OVERLAY`,
    /// `WIFI` otherwise).
    public var type: String?
    /// `state ON` (`OFF`, `DOZE`, …): whether the panel is lit. A folded
    /// foldable has its cover ON and its inner screen OFF.
    public var state: String?
    /// The four `RoundedCorners`; nil when the block prints none (before
    /// API 31, or a display without rounded-corner config).
    public var topLeft: RoundedCorner?
    public var topRight: RoundedCorner?
    public var bottomRight: RoundedCorner?
    public var bottomLeft: RoundedCorner?
    /// The camera cutout; nil when the display has none or the block
    /// carries no spec (before API 31).
    public var cutout: Cutout?

    public init(
        uniqueId: String,
        name: String,
        width: Int,
        height: Int,
        densityDpi: Int? = nil,
        xDpi: Double? = nil,
        yDpi: Double? = nil,
        type: String? = nil,
        state: String? = nil,
        topLeft: RoundedCorner? = nil,
        topRight: RoundedCorner? = nil,
        bottomRight: RoundedCorner? = nil,
        bottomLeft: RoundedCorner? = nil,
        cutout: Cutout? = nil
    ) {
        self.uniqueId = uniqueId
        self.name = name
        self.width = width
        self.height = height
        self.densityDpi = densityDpi
        self.xDpi = xDpi
        self.yDpi = yDpi
        self.type = type
        self.state = state
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
        self.cutout = cutout
    }

    /// The natural size in pixels.
    public var naturalSize: CGSize {
        CGSize(width: width, height: height)
    }

    public var isOn: Bool { state == "ON" }

    /// A built-in panel. Virtual displays (a screen recorder's, scrcpy's own
    /// on some versions) and overlays can share a frame's size but carry no
    /// corners or cutout, so matching prefers built-in panels.
    public var isBuiltIn: Bool { type == "INTERNAL" }

    /// The raw cutout spec, as printed.
    public var cutoutSpec: String? { cutout?.spec }

    /// The cutout outline in display pixels (natural orientation, top-left
    /// origin); nil when there is none or the spec does not parse.
    public var cutoutPath: CGPath? { cutout?.path }

    /// The largest corner radius in display pixels, 0 when none is reported.
    ///
    /// This is the one radius to clip a screen with. The four agree on every
    /// display captured so far, but Android sizes the top and bottom pair
    /// separately (`rounded_corner_radius_top`/`_bottom`), and a single clip
    /// must round off every corner of the glass: with the largest, no square
    /// video corner can show past a rounded bezel opening. The cost, should
    /// a device ever report unequal pairs, is that the smaller corners hide
    /// a few pixels the device itself shows.
    public var maxCornerRadius: Int {
        [topLeft, topRight, bottomRight, bottomLeft].compactMap { $0?.radius }.max() ?? 0
    }

    /// How many pixels of `size` one display pixel spans, when `size` shows
    /// this display in either orientation at any scale: the smaller of the
    /// short-side and long-side ratios, so a stream whose sides were rounded
    /// (scrcpy's multiples of 8) still fits. 0 for an empty size.
    public func scale(toFit size: CGSize) -> CGFloat {
        let short = CGFloat(min(width, height))
        let long = CGFloat(max(width, height))
        guard short > 0, size.width > 0, size.height > 0 else { return 0 }
        return min(
            min(size.width, size.height) / short,
            max(size.width, size.height) / long
        )
    }

    /// `maxCornerRadius` in the pixels (or points) of `size`, the same
    /// display shown at that size in either orientation.
    public func clipCornerRadius(scaledTo size: CGSize) -> CGFloat {
        CGFloat(maxCornerRadius) * scale(toFit: size)
    }

    // MARK: - Matching a frame

    /// How far a frame's aspect ratio may stray from a display's and still
    /// show it: a downscaled stream rounds its sides (scrcpy to multiples of
    /// 8), while a foldable's other screen differs by far more. The same
    /// bound as the app's `MirrorDisplayMetrics.shapeTolerance`.
    public static let aspectTolerance: CGFloat = 0.03

    /// The display a streamed frame of `frame` pixels shows, in either
    /// orientation: exactly the natural size first, else the closest aspect
    /// ratio within `aspectTolerance`. Built-in panels are tried before any
    /// other display, and a lit one wins a tie, so a foldable's inner and
    /// cover screens are told apart by the live frame. Nil when none fits.
    public static func matching(frame: CGSize, in shapes: [DisplayShape]) -> DisplayShape? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let frameShort = min(frame.width, frame.height)
        let frameLong = max(frame.width, frame.height)
        let frameAspect = frameLong / frameShort

        for group in [shapes.filter(\.isBuiltIn), shapes.filter { !$0.isBuiltIn }] {
            let exact = group.filter {
                CGFloat(min($0.width, $0.height)) == frameShort
                    && CGFloat(max($0.width, $0.height)) == frameLong
            }
            if let shape = exact.first(where: \.isOn) ?? exact.first {
                return shape
            }

            var best: (shape: DisplayShape, deviation: CGFloat)?
            for shape in group {
                let short = CGFloat(min(shape.width, shape.height))
                guard short > 0 else { continue }
                let aspect = CGFloat(max(shape.width, shape.height)) / short
                let deviation = abs(frameAspect / aspect - 1)
                guard deviation <= aspectTolerance else { continue }
                if let current = best {
                    let closer = deviation < current.deviation
                    let litTie = deviation == current.deviation && shape.isOn && !current.shape.isOn
                    guard closer || litTie else { continue }
                }
                best = (shape, deviation)
            }
            if let best { return best.shape }
        }
        return nil
    }

    // MARK: - Parsing

    /// Every display device in `adb shell dumpsys display` output, in dump
    /// order: one per `DisplayDeviceInfo{…}` line. Lines that are not one,
    /// or whose name, id or size do not read, are skipped; an absent field
    /// stays nil. Lines may end in `\r\n` (see `AdbParsing.packages`).
    public static func parse(dumpsysDisplay output: String) -> [DisplayShape] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.hasPrefix("DisplayDeviceInfo{\"") else { return nil }
            return DisplayShape(displayDeviceInfo: trimmed)
        }
    }

    /// Reads one `DisplayDeviceInfo.toString()` line:
    /// `DisplayDeviceInfo{"<name>": uniqueId="<id>", <w> x <h>, …, density
    /// <dpi>, <x> x <y> dpi, …, cutout DisplayCutout{…}, …, type <type>, …,
    /// state <state>, …, roundedCorners RoundedCorners{[…]}, …}`. Fields are
    /// looked up by their `, <name> ` prefix after the id, never by position:
    /// the list between them grows with every release.
    init?(displayDeviceInfo line: Substring) {
        guard let afterOpen = Self.text(in: line, after: "DisplayDeviceInfo{\""),
              let nameEnd = afterOpen.range(of: "\": uniqueId=\"")
        else { return nil }
        let afterIdOpen = afterOpen[nameEnd.upperBound...]
        guard let idEnd = afterIdOpen.firstIndex(of: "\"") else { return nil }
        let fields = afterIdOpen[afterIdOpen.index(after: idEnd)...]
        guard fields.hasPrefix(", ") else { return nil }
        let size = Self.text(fields.dropFirst(2), upTo: ",")
            .components(separatedBy: " x ")
        guard size.count == 2,
              let width = Int(size[0]), let height = Int(size[1]),
              width > 0, height > 0
        else { return nil }

        self.init(
            uniqueId: String(afterIdOpen[..<idEnd]),
            name: String(afterOpen[..<nameEnd.lowerBound]),
            width: width,
            height: height
        )

        // `density 390, 390.0 x 390.0 dpi`
        if let density = Self.text(in: fields, after: ", density ") {
            densityDpi = Int(Self.text(density, upTo: ","))
            if let dpi = Self.text(in: density, after: ", ") {
                let axes = Self.text(dpi, upTo: " dpi").components(separatedBy: " x ")
                if axes.count == 2 {
                    xDpi = Double(axes[0])
                    yDpi = Double(axes[1])
                }
            }
        }
        type = Self.text(in: fields, after: ", type ").map { String(Self.text($0, upTo: ",")) }
        state = Self.text(in: fields, after: ", state ").map { String(Self.text($0, upTo: ",")) }
        cutout = Self.cutout(in: fields, width: width, height: height)

        if let corners = Self.text(in: fields, after: "roundedCorners RoundedCorners{[") {
            for entry in Self.text(corners, upTo: "]}").components(separatedBy: "RoundedCorner{").dropFirst() {
                let entry = Substring(entry)
                guard let position = Self.text(in: entry, after: "position=").map({ Self.text($0, upTo: ",") }),
                      let radius = Self.text(in: entry, after: "radius=").flatMap({ Int(Self.text($0, upTo: ",")) }),
                      let center = Self.text(in: entry, after: "center=Point(")
                else { continue }
                let xy = Self.text(center, upTo: ")").components(separatedBy: ", ")
                guard xy.count == 2, let x = Int(xy[0]), let y = Int(xy[1]) else { continue }
                let corner = RoundedCorner(radius: radius, centerX: x, centerY: y)
                switch position {
                case "TopLeft": topLeft = corner
                case "TopRight": topRight = corner
                case "BottomRight": bottomRight = corner
                case "BottomLeft": bottomLeft = corner
                default: break
                }
            }
        }
    }

    /// `cutoutPathParserInfo={CutoutPathParserInfo{displayWidth=… displayHeight=…
    /// physicalDisplayWidth=… physicalDisplayHeight=… density={…}
    /// cutoutSpec={…} rotation={…} scale={…} physicalPixelDisplaySizeRatio={…}}}`
    /// (API 31–32 print neither physical key). Nil without a spec: an empty
    /// `cutoutSpec={}` is a display without a cutout.
    private static func cutout(in fields: Substring, width: Int, height: Int) -> Cutout? {
        guard let info = text(in: fields, after: "CutoutPathParserInfo{"),
              let specStart = info.range(of: "cutoutSpec={")
        else { return nil }
        let afterSpec = info[specStart.upperBound...]
        // Path data and markers never contain a brace.
        guard let specEnd = afterSpec.firstIndex(of: "}") else { return nil }
        let spec = afterSpec[..<specEnd].trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return nil }

        let head = info[..<specStart.lowerBound]
        let tail = text(afterSpec[specEnd...], upTo: "}}")
        func int(_ key: String, in part: Substring) -> Int? {
            text(in: part, after: key).flatMap { Int(text($0, upTo: " ")) }
        }
        func braced(_ key: String, in part: Substring) -> Double? {
            text(in: part, after: key + "={").flatMap { Double(text($0, upTo: "}")) }
        }
        guard let density = braced("density", in: head) else { return nil }
        let displayWidth = int("displayWidth=", in: head) ?? width
        let displayHeight = int("displayHeight=", in: head) ?? height
        return Cutout(
            spec: spec,
            density: density,
            physicalWidth: int("physicalDisplayWidth=", in: head) ?? displayWidth,
            physicalHeight: int("physicalDisplayHeight=", in: head) ?? displayHeight,
            physicalPixelDisplaySizeRatio: braced("physicalPixelDisplaySizeRatio", in: tail) ?? 1,
            scale: braced("scale", in: tail) ?? 1
        )
    }

    /// The text after the first `marker` in `text`, or nil when absent.
    private static func text(in text: Substring, after marker: String) -> Substring? {
        guard let range = text.range(of: marker) else { return nil }
        return text[range.upperBound...]
    }

    /// The text before the first `terminator`, or all of it.
    private static func text(_ text: Substring, upTo terminator: String) -> Substring {
        guard let range = text.range(of: terminator) else { return text }
        return text[..<range.lowerBound]
    }
}
