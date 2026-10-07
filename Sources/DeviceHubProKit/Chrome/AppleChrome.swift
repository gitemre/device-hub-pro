import CoreGraphics
import Foundation

// MARK: - Where the chrome lives

/// Xcode's DeviceKit folder, read at runtime: the device chromes
/// (`Chrome/<name>.devicechrome`) and the screens' exact outlines
/// (`FramebufferMasks/<id>.pdf`). Nothing in it is copied into the
/// repository or the app (§3.5); without it the simulator's
/// stage keeps the vector body.
public struct AppleDeviceKit: Sendable, Hashable {
    public static let defaultRoot = URL(fileURLWithPath: "/Library/Developer/DeviceKit", isDirectory: true)

    public var root: URL

    public init(root: URL = AppleDeviceKit.defaultRoot) {
        self.root = root
    }

    var chromeDirectory: URL { root.appendingPathComponent("Chrome", isDirectory: true) }
    var masksDirectory: URL { root.appendingPathComponent("FramebufferMasks", isDirectory: true) }

    /// The bundle of the chrome named `identifier`
    /// (`com.apple.dt.devicekit.chrome.phone11`): `phone11.devicechrome`
    /// when its `chrome.json` names that identifier, else the first bundle
    /// whose `chrome.json` does. Nil when none does or the folder is
    /// unreadable. Reads files: call it off the main thread.
    public func chromeBundle(identifier: String) -> URL? {
        guard !identifier.isEmpty else { return nil }
        if let suffix = identifier.split(separator: ".").last, !suffix.isEmpty {
            let guess = chromeDirectory.appendingPathComponent("\(suffix).devicechrome", isDirectory: true)
            if Self.identifier(ofBundle: guess) == identifier { return guess }
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: chromeDirectory.path) else {
            return nil
        }
        for name in names.sorted() where name.hasSuffix(".devicechrome") {
            let bundle = chromeDirectory.appendingPathComponent(name, isDirectory: true)
            if Self.identifier(ofBundle: bundle) == identifier { return bundle }
        }
        return nil
    }

    /// `FramebufferMasks/<identifier>.pdf` when it exists.
    public func framebufferMask(identifier: String) -> URL? {
        guard Self.isPlainName(identifier) else { return nil }
        let url = masksDirectory.appendingPathComponent("\(identifier).pdf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A chrome bundle's `chrome.json`.
    public static func descriptorURL(ofBundle bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/chrome.json")
    }

    /// An image of a chrome bundle: `Contents/Resources/<name>.pdf`.
    public static func imageURL(_ name: String, inBundle bundle: URL) -> URL? {
        guard isPlainName(name) else { return nil }
        return bundle.appendingPathComponent("Contents/Resources/\(name).pdf")
    }

    private static func identifier(ofBundle bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: descriptorURL(ofBundle: bundle)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["identifier"] as? String
    }

    /// A file name, not a path: no separator and no parent reference, so a
    /// name read from a plist cannot point outside the folder it is read in.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }
}

// MARK: - The chrome's artwork

/// A device chrome's PDFs, loaded once and drawn at any size: the nine
/// slices, each button's normal and pressed look, and the screen's outline
/// (the device type's framebuffer mask), when there is one.
///
/// Immutable after `load`; drawing is serialized by a lock, since a page may
/// be drawn from the main thread (the live stage) and a render queue (the
/// stopped page's preview, a framed screenshot) at once. Two loads of the
/// same files are equal, so a composition planned with either caches alike.
public final class AppleChromeArt: @unchecked Sendable, Hashable, CustomStringConvertible {
    public let descriptor: AppleChromeDescriptor
    public let bundle: URL
    public let maskURL: URL?
    private let documents: [String: CGPDFDocument]
    private let maskDocument: CGPDFDocument?
    private let lock = NSLock()

    init(descriptor: AppleChromeDescriptor, bundle: URL, maskURL: URL?, documents: [String: CGPDFDocument], maskDocument: CGPDFDocument?) {
        self.descriptor = descriptor
        self.bundle = bundle
        self.maskURL = maskURL
        self.documents = documents
        self.maskDocument = maskDocument
    }

    /// The chrome in `bundle` with the screen outline at `maskURL`; nil when
    /// its `chrome.json` does not parse or a slice is missing. A button whose
    /// images are missing is left out; a missing or unreadable mask leaves
    /// the screen's corner to the display's radius. Reads files: call it off
    /// the main thread.
    public static func load(bundle: URL, maskURL: URL?) -> AppleChromeArt? {
        guard let data = try? Data(contentsOf: AppleDeviceKit.descriptorURL(ofBundle: bundle)),
              var descriptor = AppleChromeDescriptor.parse(chromeJSON: data)
        else { return nil }
        var documents: [String: CGPDFDocument] = [:]
        func load(_ name: String) -> CGPDFDocument? {
            if let document = documents[name] { return document }
            guard let url = AppleDeviceKit.imageURL(name, inBundle: bundle),
                  let document = CGPDFDocument(url as CFURL),
                  let page = document.page(at: 1),
                  !page.getBoxRect(.mediaBox).isEmpty
            else { return nil }
            documents[name] = document
            return document
        }
        for name in descriptor.slices.all {
            guard load(name) != nil else { return nil }
        }
        descriptor.inputs = descriptor.inputs.filter { input in
            load(input.image) != nil && (input.imageDown.map { load($0) != nil } ?? true)
        }
        let mask = maskURL.flatMap { url -> CGPDFDocument? in
            guard let document = CGPDFDocument(url as CFURL),
                  let page = document.page(at: 1),
                  !page.getBoxRect(.mediaBox).isEmpty
            else { return nil }
            return document
        }
        return AppleChromeArt(
            descriptor: descriptor,
            bundle: bundle,
            maskURL: mask == nil ? nil : maskURL,
            documents: documents,
            maskDocument: mask
        )
    }

    /// An image's page size, chrome points.
    public func size(of image: String) -> CGSize? {
        documents[image]?.page(at: 1)?.getBoxRect(.mediaBox).size
    }

    /// Whether the screen's own outline was loaded.
    public var hasMask: Bool { maskDocument != nil }

    /// Draws `image` into `rect` of a y-down context (top-left origin, as
    /// SwiftUI's), stretched to it.
    public func draw(_ image: String, in rect: CGRect, context: CGContext) {
        guard let document = documents[image] else { return }
        drawPage(of: document, in: rect, context: context)
    }

    /// Draws the screen's outline (opaque inside) into `rect` of a y-down
    /// context; nothing without a mask.
    public func drawMask(in rect: CGRect, context: CGContext) {
        guard let maskDocument else { return }
        drawPage(of: maskDocument, in: rect, context: context)
    }

    private func drawPage(of document: CGPDFDocument, in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        lock.withLock {
            guard let page = document.page(at: 1) else { return }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return }
            context.saveGState()
            // A slice's page draws past its box (the 1 pt edge slices
            // stretched along the edge would lay those parts over their
            // neighbours): only the box is shown. The clip is not
            // antialiased, so two slices meeting inside a pixel share it
            // (each pixel goes to the one holding its centre) instead of
            // both covering it partly, which left a lighter seam.
            context.setShouldAntialias(false)
            context.clip(to: rect)
            context.setShouldAntialias(true)
            // PDF space is y-up: map the page's box onto `rect`, flipped.
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: rect.width / box.width, y: -rect.height / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
    }

    public static func == (lhs: AppleChromeArt, rhs: AppleChromeArt) -> Bool {
        lhs === rhs || (lhs.bundle.standardizedFileURL == rhs.bundle.standardizedFileURL
            && lhs.maskURL?.standardizedFileURL == rhs.maskURL?.standardizedFileURL
            && lhs.descriptor == rhs.descriptor)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundle.standardizedFileURL.path)
        hasher.combine(maskURL?.standardizedFileURL.path)
    }

    public var description: String {
        "AppleChromeArt(\(descriptor.identifier), mask: \(maskURL?.lastPathComponent ?? "none"))"
    }
}

// MARK: - Geometry

/// A chrome built around one screen: the frame is made from the slices at
/// the screen's point size (one chrome serves several screens, so its
/// composite preview is never drawn), in the device's native portrait.
/// Chrome points, top-left based, in the canvas: the slices' box plus the
/// room the buttons need.
///
/// Rules, measured against Device Hub (Xcode 27.0 27A266a; iPhone 17 Pro's
/// `phone11` and iPad Pro 11-inch (M5)'s `tablet5`, the parity audit
/// SIM-17):
/// - the box is the screen widened by `sizing` on each side; its outer
///   point is transparent, so the body shows `sizing − 1` pt of bezel (17 pt
///   on `phone11`, 45 on `tablet5`);
/// - the corner slices sit in the box's corners at their own size and the
///   edge slices stretch between them;
/// - a button's offset along its edge is measured from the box (the top
///   for a side button, not the padded canvas);
/// - a side or top button drawn under the body stands `buttonReach − offset`
///   past the box's edge: 3 pt at rest for the offset 8, 8 pt rolled out
///   for 3 (measured at rest: 2.35–2.8 pt in Device Hub, 2.5–3.2 pt here);
/// - a button drawn over the body (a Home button) sits `offset` in from the
///   box's edge (not measured: no device type with a Home button runs on
///   the installed runtimes);
/// - the canvas is the box plus `devicePadding` on each side, widened
///   further where a rolled-out button would stand past it.
public struct AppleChromeLayout: Sendable, Hashable {
    /// How far past the box's edge the reference line of a side button's
    /// offset lies, chrome points (see the rules above).
    public static let buttonReach: CGFloat = 11

    public struct Piece: Sendable, Hashable {
        public var image: String
        public var rect: CGRect
    }

    public struct Button: Sendable, Hashable {
        /// Its index in `AppleChromeDescriptor.inputs`.
        public var index: Int
        public var input: AppleChromeDescriptor.Input
        public var rest: CGRect
        public var rollover: CGRect
    }

    public var canvasSize: CGSize
    /// The slices' box.
    public var box: CGRect
    public var screen: CGRect
    /// What the slices leave uncovered inside them, under the screen: filled
    /// with the body's black glass (it shows before the first frame and in
    /// letterbox bars). Never the whole screen rect, whose corners lie
    /// outside the body's rounded corners.
    public var glass: CGRect
    /// The nine slices, corners first.
    public var slices: [Piece]
    public var buttons: [Button]
    /// The body's outer corner, chrome points (`simpleOutsideBorder`).
    public var outerCornerRadius: CGFloat

    /// The frame of `descriptor` around a screen of `screenPoints`; nil for
    /// an empty screen or a slice without a size.
    public static func make(
        descriptor: AppleChromeDescriptor,
        screenPoints: CGSize,
        imageSize: (String) -> CGSize?
    ) -> AppleChromeLayout? {
        guard screenPoints.width > 0, screenPoints.height > 0 else { return nil }
        let sizing = descriptor.sizing
        let width = screenPoints.width + CGFloat(sizing.left + sizing.right)
        let height = screenPoints.height + CGFloat(sizing.top + sizing.bottom)
        let slices = descriptor.slices
        guard let tl = imageSize(slices.topLeft), let tr = imageSize(slices.topRight),
              let bl = imageSize(slices.bottomLeft), let br = imageSize(slices.bottomRight),
              let top = imageSize(slices.top), let bottom = imageSize(slices.bottom),
              let left = imageSize(slices.left), let right = imageSize(slices.right)
        else { return nil }

        // Box space: the box at the origin.
        var pieces = [
            Piece(image: slices.topLeft, rect: CGRect(origin: .zero, size: tl)),
            Piece(image: slices.topRight, rect: CGRect(x: width - tr.width, y: 0, width: tr.width, height: tr.height)),
            Piece(image: slices.bottomRight, rect: CGRect(x: width - br.width, y: height - br.height, width: br.width, height: br.height)),
            Piece(image: slices.bottomLeft, rect: CGRect(x: 0, y: height - bl.height, width: bl.width, height: bl.height)),
            Piece(image: slices.top, rect: CGRect(x: tl.width, y: 0, width: max(width - tl.width - tr.width, 0), height: top.height)),
            Piece(image: slices.right, rect: CGRect(x: width - right.width, y: tr.height, width: right.width, height: max(height - tr.height - br.height, 0))),
            Piece(image: slices.bottom, rect: CGRect(x: bl.width, y: height - bottom.height, width: max(width - bl.width - br.width, 0), height: bottom.height)),
            Piece(image: slices.left, rect: CGRect(x: 0, y: tl.height, width: left.width, height: max(height - tl.height - bl.height, 0))),
        ]
        let box = CGRect(x: 0, y: 0, width: width, height: height)
        var buttons: [Button] = []
        for (index, input) in descriptor.inputs.enumerated() {
            guard let size = imageSize(input.image), size.width > 0, size.height > 0 else { continue }
            buttons.append(Button(
                index: index,
                input: input,
                rest: buttonRect(input, offset: input.normal, size: size, box: box),
                rollover: buttonRect(input, offset: input.rollover, size: size, box: box)
            ))
        }

        // The canvas: the padded box, and every button's farthest reach.
        let padding = descriptor.devicePadding
        var canvas = CGRect(
            x: -CGFloat(padding.left),
            y: -CGFloat(padding.top),
            width: width + CGFloat(padding.left + padding.right),
            height: height + CGFloat(padding.top + padding.bottom)
        )
        for button in buttons {
            canvas = canvas.union(button.rest).union(button.rollover)
        }
        let shift = CGAffineTransform(translationX: -canvas.minX, y: -canvas.minY)
        for index in pieces.indices {
            pieces[index].rect = pieces[index].rect.applying(shift)
        }
        for index in buttons.indices {
            buttons[index].rest = buttons[index].rest.applying(shift)
            buttons[index].rollover = buttons[index].rollover.applying(shift)
        }
        let placedBox = box.applying(shift)
        let glass = CGRect(
            x: placedBox.minX + left.width,
            y: placedBox.minY + top.height,
            width: max(width - left.width - right.width, 0),
            height: max(height - top.height - bottom.height, 0)
        )
        return AppleChromeLayout(
            canvasSize: canvas.size,
            box: placedBox,
            screen: CGRect(
                x: placedBox.minX + CGFloat(sizing.left),
                y: placedBox.minY + CGFloat(sizing.top),
                width: screenPoints.width,
                height: screenPoints.height
            ),
            glass: glass,
            slices: pieces,
            buttons: buttons,
            outerCornerRadius: CGFloat(descriptor.outerCornerRadius ?? 0)
        )
    }

    /// A button's rect at `offset`, box space.
    static func buttonRect(
        _ input: AppleChromeDescriptor.Input,
        offset: CGPoint,
        size: CGSize,
        box: CGRect
    ) -> CGRect {
        let reach = input.onTop ? 0 : buttonReach
        func along(start: CGFloat, length: CGFloat, value: CGFloat, extent: CGFloat) -> CGFloat {
            switch input.align {
            case .leading: return start + value
            case .center: return start + length / 2 + value - extent / 2
            case .trailing: return start + length + value - extent
            }
        }
        switch input.anchor {
        case .left:
            let y = along(start: box.minY, length: box.height, value: offset.y, extent: size.height)
            return CGRect(x: box.minX - reach + offset.x, y: y, width: size.width, height: size.height)
        case .right:
            let y = along(start: box.minY, length: box.height, value: offset.y, extent: size.height)
            return CGRect(x: box.maxX + reach + offset.x - size.width, y: y, width: size.width, height: size.height)
        case .top:
            let x = along(start: box.minX, length: box.width, value: offset.x, extent: size.width)
            return CGRect(x: x, y: box.minY - reach + offset.y, width: size.width, height: size.height)
        case .bottom:
            let x = along(start: box.minX, length: box.width, value: offset.x, extent: size.width)
            let y = input.onTop ? box.maxY + offset.y : box.maxY + reach + offset.y - size.height
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    /// The layout's rects mapped by `transform` (all of them).
    func applying(_ transform: CGAffineTransform) -> AppleChromeLayout {
        var copy = self
        copy.box = box.applying(transform)
        copy.screen = screen.applying(transform)
        copy.glass = glass.applying(transform)
        copy.slices = slices.map { Piece(image: $0.image, rect: $0.rect.applying(transform)) }
        copy.buttons = buttons.map {
            Button(index: $0.index, input: $0.input, rest: $0.rest.applying(transform), rollover: $0.rollover.applying(transform))
        }
        return copy
    }

    /// Maps a point of a native canvas of `size` (top-left based) to the
    /// canvas turned `quarterTurns` counter-clockwise: 1 is the device
    /// turned to landscape left (its top edge on the left), as
    /// `Surface.ROTATION_90` and `CutoutPlacement` count.
    public static func turn(canvas size: CGSize, quarterTurns: Int) -> CGAffineTransform {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        case 3: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        default: return .identity
        }
    }
}

// MARK: - A simulator's frame

/// The chrome a simulator's device type is drawn in: its artwork and the
/// frame built around its display (`AppleChromeFrameProvider`).
public struct AppleChromeFrame: Sendable, Hashable {
    public var art: AppleChromeArt
    public var layout: AppleChromeLayout
    /// The display: pixels (portrait), pixels per point, corner radius in
    /// points (the corner a screen without its outline is clipped to).
    public var screenPixels: CGSize
    public var scale: CGFloat
    public var cornerRadius: CGFloat
    /// The device type's own sensor-bar picture (`profile.plist`'s
    /// `sensorBarImage`: the Dynamic Island of an iPhone 14 Pro and later),
    /// one PDF as wide as the screen in points and drawn at its top. The
    /// live simulator draws it into its framebuffer itself; a placeholder
    /// screen (the stopped device's hero) draws it here. Nil when the device
    /// type names none or the file is not there.
    public var sensorBar: URL?
    /// The device type's screen has a Dynamic Island (its sensor-bar picture
    /// is empty then: the island is the simulator's own drawing).
    public var hasDynamicIsland: Bool

    public init(
        art: AppleChromeArt,
        layout: AppleChromeLayout,
        screenPixels: CGSize,
        scale: CGFloat,
        cornerRadius: CGFloat,
        sensorBar: URL? = nil,
        hasDynamicIsland: Bool = false
    ) {
        self.art = art
        self.layout = layout
        self.screenPixels = screenPixels
        self.scale = scale
        self.cornerRadius = cornerRadius
        self.sensorBar = sensorBar
        self.hasDynamicIsland = hasDynamicIsland
    }

    /// The chrome's name for tests and logs: `phone11`.
    public var chromeName: String {
        art.descriptor.identifier.split(separator: ".").last.map(String.init) ?? art.descriptor.identifier
    }
}

/// Finds and loads the Apple chrome of a simulator device type (design
/// §3.5, device-frame Tier 2): the device type's display names its chrome
/// (`chromeIdentifier`) and its screen outline (`framebufferMaskIdentifier`),
/// with the device type's `profile.plist` (`chromeIdentifier`,
/// `framebufferMask`) as the fallback; the chrome is read from DeviceKit,
/// the outline from DeviceKit's `FramebufferMasks`, else from the device
/// type's own resources. Nil when the device type names no chrome (Apple TV
/// device types name none) or the chrome cannot be read: the stage then
/// keeps the vector body.
public struct AppleChromeFrameProvider: Sendable {
    public var deviceKit: AppleDeviceKit

    public init(deviceKit: AppleDeviceKit = AppleDeviceKit()) {
        self.deviceKit = deviceKit
    }

    /// Reads files: call it off the main thread.
    public func frame(deviceTypeBundle bundle: URL, display: SimulatorDisplayProfile) -> AppleChromeFrame? {
        let profile = Self.profile(ofDeviceType: bundle)
        guard let identifier = display.chromeIdentifier ?? profile["chromeIdentifier"] as? String,
              let chromeBundle = deviceKit.chromeBundle(identifier: identifier)
        else { return nil }
        let maskID = display.framebufferMaskIdentifier ?? profile["framebufferMask"] as? String
        let mask = maskID.flatMap { id in
            deviceKit.framebufferMask(identifier: id) ?? Self.deviceTypeMask(id, bundle: bundle)
        }
        guard let art = AppleChromeArt.load(bundle: chromeBundle, maskURL: mask) else { return nil }
        guard var frame = Self.frame(art: art, display: display) else { return nil }
        frame.sensorBar = Self.sensorBar(named: profile["sensorBarImage"] as? String, bundle: bundle)
        return frame
    }

    /// `<name>.pdf` in the device type's resources when the profile names
    /// one and the file is there.
    static func sensorBar(named name: String?, bundle: URL) -> URL? {
        guard let name, AppleDeviceKit.isPlainName(name) else { return nil }
        let url = bundle.appendingPathComponent("Contents/Resources/\(name).pdf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The frame of `art` around `display`; nil for a display without a
    /// scale or a size, or a chrome whose slices have no size.
    public static func frame(art: AppleChromeArt, display: SimulatorDisplayProfile) -> AppleChromeFrame? {
        let scale = CGFloat(display.scale)
        guard scale > 0, display.width > 0, display.height > 0 else { return nil }
        let pixels = CGSize(width: min(display.width, display.height), height: max(display.width, display.height))
        guard let layout = AppleChromeLayout.make(
            descriptor: art.descriptor,
            screenPoints: CGSize(width: pixels.width / scale, height: pixels.height / scale),
            imageSize: art.size(of:)
        ) else { return nil }
        let corner = [display.topLeftRadius, display.topRightRadius, display.bottomRightRadius, display.bottomLeftRadius].max() ?? 0
        return AppleChromeFrame(
            art: art,
            layout: layout,
            screenPixels: pixels,
            scale: scale,
            cornerRadius: CGFloat(corner),
            hasDynamicIsland: display.hasDynamicIsland
        )
    }

    private static func profile(ofDeviceType bundle: URL) -> [String: Any] {
        let url = bundle.appendingPathComponent("Contents/Resources/profile.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return root
    }

    private static func deviceTypeMask(_ identifier: String, bundle: URL) -> URL? {
        guard AppleDeviceKit.isPlainName(identifier) else { return nil }
        let url = bundle.appendingPathComponent("Contents/Resources/\(identifier).pdf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Drawing

/// Draws a chrome frame with CoreGraphics, into a y-down context (top-left
/// origin, as SwiftUI's `Canvas` and a flipped bitmap are) whose units are
/// chrome points. The live stage (`AppleChromeDeviceView`) and the static
/// renders (`DeviceCompositionRenderer`) share these, so the two draw the
/// same frame.
public enum AppleChromeDrawing {
    /// The body: the black glass the slices leave uncovered, then the nine
    /// slices.
    public static func drawBody(_ layout: AppleChromeLayout, art: AppleChromeArt, in context: CGContext) {
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(layout.glass)
        for piece in layout.slices {
            art.draw(piece.image, in: piece.rect, context: context)
        }
    }

    /// The buttons drawn under the body (`onTop` false) or over it, each at
    /// rest and not pressed.
    public static func drawButtons(_ layout: AppleChromeLayout, art: AppleChromeArt, onTop: Bool, in context: CGContext) {
        for button in layout.buttons where button.input.onTop == onTop {
            drawButton(button.input, art: art, pressed: false, in: button.rest, context: context)
        }
    }

    /// One button's look: its normal image, or pressed its pressed image
    /// instead (`replace`) or under the normal one (`compositeUnder`).
    public static func drawButton(
        _ input: AppleChromeDescriptor.Input,
        art: AppleChromeArt,
        pressed: Bool,
        in rect: CGRect,
        context: CGContext
    ) {
        guard pressed, let down = input.imageDown else {
            art.draw(input.image, in: rect, context: context)
            return
        }
        switch input.downDrawMode {
        case .replace:
            art.draw(down, in: rect, context: context)
        case .compositeUnder:
            art.draw(down, in: rect, context: context)
            art.draw(input.image, in: rect, context: context)
        }
    }

    /// Black over the screen rect's corners outside the screen's outline
    /// (the framebuffer mask), transparent inside, only within `within`:
    /// drawn over a video already clipped to `within` (the live stage clips
    /// it to a continuous-corner rounded rect a little larger than the
    /// outline), it trims the video to the exact outline, over the body's
    /// black glass. Nothing is drawn outside `within`, where the screen
    /// rect's corners reach past the body's rounded corners. Without a mask,
    /// a rounded rect of `cornerRadius` (circular corners) stands in.
    public static func drawScreenCorners(
        in rect: CGRect,
        within: CGPath,
        art: AppleChromeArt,
        cornerRadius: CGFloat,
        context: CGContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.addPath(within)
        context.clip()
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(rect)
        context.setBlendMode(.destinationOut)
        if art.hasMask {
            art.drawMask(in: rect, context: context)
        } else {
            let radius = min(max(cornerRadius, 0), rect.width / 2, rect.height / 2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Clips a y-up `context` to the screen's outline at `rect`, the screen
    /// turned `quarterTurns` counter-clockwise: the framebuffer mask,
    /// rendered turned at `rect`'s size (rounded to whole pixels) as a gray
    /// image, or without one a rounded rect of `cornerRadius` (`rect`'s
    /// units). For static renders; the live stage clips its video on its
    /// layer.
    public static func clipToScreen(
        _ rect: CGRect,
        quarterTurns: Int,
        art: AppleChromeArt,
        cornerRadius: CGFloat,
        context: CGContext
    ) {
        if art.hasMask, let mask = maskImage(art: art, size: rect.size, quarterTurns: quarterTurns) {
            context.clip(to: rect, mask: mask)
            return
        }
        let radius = min(max(cornerRadius, 0), rect.width / 2, rect.height / 2)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
    }

    /// The outline turned `quarterTurns` counter-clockwise as a DeviceGray
    /// image of `size` (the turned size): white inside, its first row the
    /// outline's top, which `clip(to:mask:)` puts at the rect's top in a
    /// y-up space.
    static func maskImage(art: AppleChromeArt, size: CGSize, quarterTurns: Int) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        let turns = ((quarterTurns % 4) + 4) % 4
        let native = turns % 2 == 1 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            // `drawMask` takes a y-down space: the buffer's first row on top.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.concatenate(AppleChromeLayout.turn(canvas: native, quarterTurns: turns))
            art.drawMask(in: CGRect(origin: .zero, size: native), context: context)
            return true
        }
        guard drawn, let provider = CGDataProvider(data: Data(alpha) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

// MARK: - Pose

/// How a simulator in Apple chrome turns: the chrome follows the device's
/// orientation (Device Hub turns the whole device, its screen with it), and
/// the screen shows the simulator's native framebuffer, so an interface that
/// does not turn (the iPhone home screen) shows sideways in a landscape
/// device, as in Device Hub; one that turns shows upright.
public enum AppleChromePose {
    /// Counter-clockwise quarter turns of a device orientation: landscape
    /// left (the top on the left) is 1.
    public static func turns(for orientation: SimulatorOrientation) -> Int {
        switch orientation {
        case .portrait: return 0
        case .landscapeLeft: return 1
        case .portraitUpsideDown: return 2
        case .landscapeRight: return 3
        }
    }

    /// The quarter turns of a published frame's rotation, in the same count:
    /// `counterClockwise` (`uiOrientation` 4, the interface of landscape
    /// left) is 1.
    public static func turns(for rotation: SimulatorFrameRotation) -> Int {
        switch rotation {
        case .upright: return 0
        case .counterClockwise: return 1
        case .upsideDown: return 2
        case .clockwise: return 3
        }
    }

    /// How far a published frame of `frame` pixels is turned from the
    /// native panel of `native` pixels (the frames are posed by the
    /// interface orientation): the rotation the session `reported` when it
    /// fits the frame's shape; else, for a frame of the other shape than the
    /// panel, the device's turn when it is a landscape one (the interface
    /// followed the device) or landscape left; else upright.
    public static func contentTurns(
        frame: CGSize,
        native: CGSize,
        reported: SimulatorFrameRotation?,
        deviceTurns: Int
    ) -> Int {
        let swapped = frame.width != frame.height
            && native.width != native.height
            && (frame.width > frame.height) != (native.width > native.height)
        if let reported, reported.swapsAxes == swapped {
            return turns(for: reported)
        }
        guard swapped else { return 0 }
        let device = ((deviceTurns % 4) + 4) % 4
        return device % 2 == 1 ? device : 1
    }
}
