import CoreGraphics
import Foundation

/// The chrome's colours reuse the annotation model's `RGBA` (components in
/// 0...1, `Annotation.swift`). A composition is compared and cached by
/// value, so the colour must hash; the conformance is written out because
/// Swift only synthesizes one in the type's own file.
extension RGBA: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(red)
        hasher.combine(green)
        hasher.combine(blue)
        hasher.combine(alpha)
    }
}

extension RGBA {
    /// The colour in sRGB, the space every chrome value (`ChromeSpec`, a
    /// skin's `Backing`) is given in: chrome is drawn with this, never with
    /// the annotation model's `cgColor`, which builds a Generic RGB colour
    /// and so lands the highlight's #7E7E7E as #919191 in an sRGB bitmap.
    var srgbColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// What kind of body a skinless screen is drawn in; picks the bezel width
/// (`ChromeSpec.standard(_:)`).
public enum DeviceFamily: Sendable, Hashable {
    case phone
    /// A foldable's large inner screen, unfolded.
    case foldableInner
    case tablet
}

/// One flat band of the body, outside-in: `widthMM` of `color`.
public struct ChromeBand: Sendable, Hashable {
    public var widthMM: Double
    public var color: RGBA

    public init(widthMM: Double, color: RGBA) {
        self.widthMM = widthMM
        self.color = color
    }
}

/// The vector device body drawn around a screen that has no skin (physical
/// phones, skinless AVDs), in millimetres so it keeps a real device's
/// proportions at any resolution: a rounded body `bezelMM` wider than the
/// screen on every side, concentric with the screen's own corner, made of
/// flat bands like Device Hub's chrome. No gradients and no shadow, as there.
public struct ChromeSpec: Sendable, Hashable {
    /// From the screen edge to the body edge.
    public var bezelMM: Double
    /// Outside-in: rim, highlight, frame.
    public var bands: [ChromeBand]
    /// The rest of the body inside the bands, the screen's surround included
    /// (it shows before the first frame and in letterbox bars).
    public var glass: RGBA

    public init(bezelMM: Double, bands: [ChromeBand], glass: RGBA) {
        self.bezelMM = bezelMM
        self.bands = bands
        self.glass = glass
    }

    /// The body for `family`.
    ///
    /// Bezels:
    /// - phone 3.3 mm: the median artwork bezel of the 18 modern Pixel SDK
    ///   skins (4a … 10 Pro XL, 2.03–4.09 mm, median 3.28 mm), inside
    ///   Apple's phone chromes (18–22 pt at 3x / 460 ppi, 2.98–3.64 mm);
    /// - foldableInner 4.3 mm: `pixel_10_pro_fold`'s unfolded artwork
    ///   measures 3.95–4.49 mm;
    /// - tablet 9.5 mm: Apple's tablet chromes measure 8.8–11.5 mm.
    ///
    /// Bands are Device Hub's `phone13` chrome layers (the vector slice PDFs
    /// in Xcode's DeviceKit), converted at 1 pt = 0.166 mm (3 px at 460 ppi):
    ///
    /// | Band | Width | Colour |
    /// |---|---|---|
    /// | rim | 1 pt, 0.166 mm | black at 0.148 |
    /// | highlight | 1 pt, 0.166 mm | #7E7E7E |
    /// | frame | 4 pt, 0.663 mm | #2C2C2C |
    /// | glass | the rest | #010101 |
    public static func standard(_ family: DeviceFamily) -> ChromeSpec {
        let bezel: Double
        switch family {
        case .phone: bezel = 3.3
        case .foldableInner: bezel = 4.3
        case .tablet: bezel = 9.5
        }
        return ChromeSpec(
            bezelMM: bezel,
            bands: [
                ChromeBand(widthMM: 0.166, color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.148)),
                ChromeBand(widthMM: 0.166, color: gray(0x7E)),
                ChromeBand(widthMM: 0.663, color: gray(0x2C)),
            ],
            glass: gray(0x01)
        )
    }

    /// An opaque grey of one 8-bit sRGB level.
    private static func gray(_ level: Int) -> RGBA {
        let value = Double(level) / 255
        return RGBA(red: value, green: value, blue: value)
    }
}
