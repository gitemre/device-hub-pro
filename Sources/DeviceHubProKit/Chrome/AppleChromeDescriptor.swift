import CoreGraphics
import Foundation

/// A DeviceKit device chrome's `chrome.json`: the nine slices its frame is
/// built from, how far the frame reaches past the screen, and its buttons.
///
/// The file is Apple's and stays on the user's Mac: it is read at runtime
/// from `/Library/Developer/DeviceKit/Chrome/<name>.devicechrome/Contents/
/// Resources/chrome.json` (`AppleDeviceKit`), never copied into the
/// repository or the app (§3.5). Only the keys below are read;
/// the rest (`resizeRects`, the window `padding`, a TV's `stand`) are not
/// used.
public struct AppleChromeDescriptor: Sendable, Hashable {
    /// Distances in chrome points (a device point: 1206 px at 3x is 402 pt).
    public struct Insets: Sendable, Hashable {
        public var top: Double
        public var left: Double
        public var bottom: Double
        public var right: Double

        public init(top: Double, left: Double, bottom: Double, right: Double) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        public static let zero = Insets(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// The body edge a button sits on.
    public enum Anchor: String, Sendable, Hashable {
        case left, right, top, bottom
    }

    /// Where along its edge a button's offset is measured from: the edge's
    /// start (top or left), its middle, or its end.
    public enum Align: String, Sendable, Hashable {
        case leading, center, trailing
    }

    /// How a pressed button is drawn: its pressed image instead of the
    /// normal one, or under it (a Home button's ring).
    public enum DownDrawMode: String, Sendable, Hashable {
        case replace
        case compositeUnder
    }

    /// One hardware button of the chrome (`inputs[]` of type `button`).
    public struct Input: Sendable, Hashable {
        /// "action", "volume-up", "power", "home", …
        public var name: String
        /// "Sleep/Wake", "Volume Up", …: what VoiceOver says.
        public var title: String
        /// The HID usage the button sends.
        public var usagePage: UInt32
        public var usage: UInt32
        /// Image names in the bundle (PDFs); `imageDown` is the pressed look.
        public var image: String
        public var imageDown: String?
        public var downDrawMode: DownDrawMode
        /// Drawn over the body (a Home button) rather than under it (a side
        /// button, whose body edge hides its inner part).
        public var onTop: Bool
        public var anchor: Anchor
        public var align: Align
        /// Chrome points: at rest, and rolled out under the pointer.
        public var normal: CGPoint
        public var rollover: CGPoint

        public init(
            name: String,
            title: String,
            usagePage: UInt32,
            usage: UInt32,
            image: String,
            imageDown: String?,
            downDrawMode: DownDrawMode = .replace,
            onTop: Bool = false,
            anchor: Anchor,
            align: Align = .leading,
            normal: CGPoint,
            rollover: CGPoint
        ) {
            self.name = name
            self.title = title
            self.usagePage = usagePage
            self.usage = usage
            self.image = image
            self.imageDown = imageDown
            self.downDrawMode = downDrawMode
            self.onTop = onTop
            self.anchor = anchor
            self.align = align
            self.normal = normal
            self.rollover = rollover
        }
    }

    /// The nine slices' image names, clockwise from the top-left corner.
    public struct Slices: Sendable, Hashable {
        public var topLeft: String
        public var top: String
        public var topRight: String
        public var right: String
        public var bottomRight: String
        public var bottom: String
        public var bottomLeft: String
        public var left: String

        public init(
            topLeft: String,
            top: String,
            topRight: String,
            right: String,
            bottomRight: String,
            bottom: String,
            bottomLeft: String,
            left: String
        ) {
            self.topLeft = topLeft
            self.top = top
            self.topRight = topRight
            self.right = right
            self.bottomRight = bottomRight
            self.bottom = bottom
            self.bottomLeft = bottomLeft
            self.left = left
        }

        public var all: [String] { [topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left] }
    }

    /// `com.apple.dt.devicekit.chrome.phone11`.
    public var identifier: String
    public var slices: Slices
    /// The preview of the whole frame at one screen size; never drawn (one
    /// chrome serves several screen sizes, so the frame is built from the
    /// slices around the screen).
    public var composite: String?
    /// `images.sizing`: from the screen's edge to the slices' outer box.
    public var sizing: Insets
    /// `images.devicePadding`: room around the box for the buttons.
    public var devicePadding: Insets
    /// `paths.simpleOutsideBorder`'s corner radius, chrome points.
    public var outerCornerRadius: Double?
    public var inputs: [Input]

    public init(
        identifier: String,
        slices: Slices,
        composite: String? = nil,
        sizing: Insets,
        devicePadding: Insets = .zero,
        outerCornerRadius: Double? = nil,
        inputs: [Input] = []
    ) {
        self.identifier = identifier
        self.slices = slices
        self.composite = composite
        self.sizing = sizing
        self.devicePadding = devicePadding
        self.outerCornerRadius = outerCornerRadius
        self.inputs = inputs
    }

    /// Every image the frame draws: the slices and each button's two looks.
    public var imageNames: [String] {
        var names = slices.all
        for input in inputs {
            names.append(input.image)
            if let down = input.imageDown { names.append(down) }
        }
        return names
    }

    // MARK: - Parsing

    /// The descriptor of a `chrome.json`'s bytes; nil when it is not JSON,
    /// lacks an identifier, a slice or the sizing. Inputs that are not
    /// buttons, or lack an image, an anchor or a HID usage, are left out.
    public static func parse(chromeJSON data: Data) -> AppleChromeDescriptor? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = root["identifier"] as? String, !identifier.isEmpty,
              let images = root["images"] as? [String: Any]
        else { return nil }
        func name(_ key: String) -> String? {
            (images[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let topLeft = name("topLeft"), let top = name("top"), let topRight = name("topRight"),
              let right = name("right"), let bottomRight = name("bottomRight"), let bottom = name("bottom"),
              let bottomLeft = name("bottomLeft"), let left = name("left"),
              let sizingValues = images["sizing"] as? [String: Any],
              let sizing = Self.sizing(sizingValues)
        else { return nil }
        let padding = (images["devicePadding"] as? [String: Any]).map(Self.insets) ?? .zero
        let border = (root["paths"] as? [String: Any])?["simpleOutsideBorder"] as? [String: Any]
        let inputs = (root["inputs"] as? [[String: Any]] ?? []).compactMap(Self.input)
        return AppleChromeDescriptor(
            identifier: identifier,
            slices: Slices(
                topLeft: topLeft,
                top: top,
                topRight: topRight,
                right: right,
                bottomRight: bottomRight,
                bottom: bottom,
                bottomLeft: bottomLeft,
                left: left
            ),
            composite: name("composite"),
            sizing: sizing,
            devicePadding: padding,
            outerCornerRadius: number(border?["cornerRadiusX"]),
            inputs: inputs
        )
    }

    /// `sizing`'s `leftWidth`, `rightWidth`, `topHeight`, `bottomHeight`.
    private static func sizing(_ values: [String: Any]) -> Insets? {
        guard let left = number(values["leftWidth"]), let right = number(values["rightWidth"]),
              let top = number(values["topHeight"]), let bottom = number(values["bottomHeight"]),
              left >= 0, right >= 0, top >= 0, bottom >= 0
        else { return nil }
        return Insets(top: top, left: left, bottom: bottom, right: right)
    }

    private static func insets(_ values: [String: Any]) -> Insets {
        Insets(
            top: max(number(values["top"]) ?? 0, 0),
            left: max(number(values["left"]) ?? 0, 0),
            bottom: max(number(values["bottom"]) ?? 0, 0),
            right: max(number(values["right"]) ?? 0, 0)
        )
    }

    private static func input(_ values: [String: Any]) -> Input? {
        guard (values["type"] as? String) ?? "button" == "button",
              let name = values["name"] as? String,
              let image = (values["image"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
              let anchor = (values["anchor"] as? String).flatMap(Anchor.init(rawValue:)),
              let page = number(values["usagePage"]), let usage = number(values["usage"]),
              page >= 0, usage >= 0, page <= Double(UInt32.max), usage <= Double(UInt32.max)
        else { return nil }
        let offsets = values["offsets"] as? [String: Any]
        let normal = point(offsets?["normal"]) ?? .zero
        return Input(
            name: name,
            title: (values["accessibilityTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
            usagePage: UInt32(page),
            usage: UInt32(usage),
            image: image,
            imageDown: (values["imageDown"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            downDrawMode: (values["imageDownDrawMode"] as? String).flatMap(DownDrawMode.init(rawValue:)) ?? .replace,
            onTop: (values["onTop"] as? Bool) ?? false,
            anchor: anchor,
            align: (values["align"] as? String).flatMap(Align.init(rawValue:)) ?? .leading,
            normal: normal,
            rollover: point(offsets?["rollover"]) ?? normal
        )
    }

    private static func point(_ value: Any?) -> CGPoint? {
        guard let values = value as? [String: Any],
              let x = number(values["x"]), let y = number(values["y"])
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // JSON booleans arrive as NSNumber too; a flag is no distance.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        default:
            return nil
        }
    }
}
