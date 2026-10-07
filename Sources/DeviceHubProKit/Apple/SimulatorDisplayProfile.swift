import Foundation

/// A simulator device type's main display, as the device type's own
/// `capabilities.plist` declares it: its pixel size, its scale, the radius of
/// each corner and its dpi.
///
/// The file is Apple's and stays on the user's Mac: it is read at runtime
/// from the device type bundle `simctl list devicetypes` names
/// (`<bundle>/Contents/Resources/capabilities.plist`), never copied into the
/// repository or the app (§3.1). The display is the plist's
/// `displays` entry of type `integrated` (the device's own panel; the others
/// are external outputs), else the first one.
///
/// The simulator's stage draws the device-frame vector body around this
/// display: `displayShape(id:)` turns it into the
/// `DisplayShape` the planner takes, with the corner radii converted from
/// points to pixels. The device type's Apple chrome (`chromeIdentifier`,
/// `framebufferMaskIdentifier`) is found by `AppleChromeFrameProvider`.
public struct SimulatorDisplayProfile: Sendable, Hashable {
    /// Pixels, portrait: 1206 × 2622 on an iPhone 17 Pro.
    public var width: Int
    public var height: Int
    /// Pixels per point (3 on an iPhone 17 Pro).
    public var scale: Double
    /// The corner radii in points (`cornerRadiusUL`/`UR`/`LR`/`LL`), 0 for a
    /// square corner.
    public var topLeftRadius: Double
    public var topRightRadius: Double
    public var bottomRightRadius: Double
    public var bottomLeftRadius: Double
    /// `hdpi` / `vdpi`: the panel's physical dpi.
    public var horizontalDpi: Double?
    public var verticalDpi: Double?
    /// The DeviceKit chrome the device type names, for the Apple chrome tier.
    public var chromeIdentifier: String?
    /// The screen's exact outline (`FramebufferMasks/<id>.pdf`), for the
    /// Apple chrome tier.
    public var framebufferMaskIdentifier: String?
    /// `DeviceSupportsDynamicIsland` (the capabilities' own key): the device
    /// type's screen carries a Dynamic Island, which the simulator draws
    /// into its framebuffer; a placeholder screen has to draw it itself.
    public var hasDynamicIsland: Bool

    public init(
        width: Int,
        height: Int,
        scale: Double,
        topLeftRadius: Double = 0,
        topRightRadius: Double = 0,
        bottomRightRadius: Double = 0,
        bottomLeftRadius: Double = 0,
        horizontalDpi: Double? = nil,
        verticalDpi: Double? = nil,
        chromeIdentifier: String? = nil,
        framebufferMaskIdentifier: String? = nil,
        hasDynamicIsland: Bool = false
    ) {
        self.width = width
        self.height = height
        self.scale = scale
        self.topLeftRadius = topLeftRadius
        self.topRightRadius = topRightRadius
        self.bottomRightRadius = bottomRightRadius
        self.bottomLeftRadius = bottomLeftRadius
        self.horizontalDpi = horizontalDpi
        self.verticalDpi = verticalDpi
        self.chromeIdentifier = chromeIdentifier
        self.framebufferMaskIdentifier = framebufferMaskIdentifier
        self.hasDynamicIsland = hasDynamicIsland
    }

    /// Reads the device type bundle's `capabilities.plist`; nil when it is
    /// missing or declares no usable display. Reads a file: call it off the
    /// main thread.
    public static func read(deviceTypeBundle bundle: URL) -> SimulatorDisplayProfile? {
        let file = bundle.appendingPathComponent("Contents/Resources/capabilities.plist")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return parse(capabilitiesPlist: data)
    }

    /// The display of a `capabilities.plist`'s bytes.
    public static func parse(capabilitiesPlist data: Data) -> SimulatorDisplayProfile? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let capabilities = root["capabilities"] as? [String: Any]
        else { return nil }
        return parse(capabilities: capabilities)
    }

    /// The display of the plist's `capabilities` dictionary. A display
    /// without corner keys falls back to the device's `DeviceCornerRadius`,
    /// else square corners.
    public static func parse(capabilities: [String: Any]) -> SimulatorDisplayProfile? {
        guard let displays = capabilities["displays"] as? [[String: Any]], !displays.isEmpty else { return nil }
        let display = displays.first { ($0["displayType"] as? String) == "integrated" } ?? displays[0]
        guard let width = integer(display["width"]), let height = integer(display["height"]),
              width > 0, height > 0
        else { return nil }
        let scale = number(display["scale"]).flatMap { $0 > 0 ? $0 : nil } ?? 1
        let deviceCorner = number(capabilities["DeviceCornerRadius"]) ?? 0
        func corner(_ key: String) -> Double {
            max(0, number(display[key]) ?? deviceCorner)
        }
        return SimulatorDisplayProfile(
            width: width,
            height: height,
            scale: scale,
            topLeftRadius: corner("cornerRadiusUL"),
            topRightRadius: corner("cornerRadiusUR"),
            bottomRightRadius: corner("cornerRadiusLR"),
            bottomLeftRadius: corner("cornerRadiusLL"),
            horizontalDpi: number(display["hdpi"]),
            verticalDpi: number(display["vdpi"]),
            chromeIdentifier: display["chromeIdentifier"] as? String,
            framebufferMaskIdentifier: display["framebufferMaskIdentifier"] as? String,
            hasDynamicIsland: capabilities["DeviceSupportsDynamicIsland"] as? Bool ?? false
        )
    }

    /// The display as the vector body's planner takes it: a built-in panel
    /// that is on, its corners in pixels (points × scale, each a quarter
    /// circle), its physical dpi, and a logical density of 160 × scale, so a
    /// point counts as a dp and the planner's 600 dp line tells an iPad from
    /// an iPhone. No cutout: the simulator draws the Dynamic Island into its
    /// own framebuffer.
    public func displayShape(id: String) -> DisplayShape {
        func corner(_ radius: Double, _ centerX: (Int) -> Int, _ centerY: (Int) -> Int) -> DisplayShape.RoundedCorner? {
            let pixels = Int((radius * scale).rounded())
            guard pixels > 0 else { return nil }
            return DisplayShape.RoundedCorner(radius: pixels, centerX: centerX(pixels), centerY: centerY(pixels))
        }
        return DisplayShape(
            uniqueId: id,
            name: "primary",
            width: width,
            height: height,
            densityDpi: Int((160 * scale).rounded()),
            xDpi: horizontalDpi,
            yDpi: verticalDpi,
            type: "INTERNAL",
            state: "ON",
            topLeft: corner(topLeftRadius, { $0 }, { $0 }),
            topRight: corner(topRightRadius, { width - $0 }, { $0 }),
            bottomRight: corner(bottomRightRadius, { width - $0 }, { height - $0 }),
            bottomLeft: corner(bottomLeftRadius, { $0 }, { height - $0 })
        )
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map { Int($0.rounded()) }
    }
}
