import Foundation

// Daybreak's colours, kept as plain numbers. Foundation only, so `swift test`
// checks the sky on the Mac (DaybreakTests) while the app (App/) compiles the
// same file for the simulator and turns each RGB into a SwiftUI Color.

/// sRGB components 0...1.
struct RGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `0xRRGGBB`, as the palette's keyframes are written.
    init(hex: UInt32) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255
        )
    }

    /// A straight blend of the sRGB values, `t` clamped to 0...1. Cheap enough
    /// to run per frame, and close enough to a perceptual blend between the
    /// palette's neighbouring keyframes, which are near in hue.
    func mixed(with other: RGB, _ t: Double) -> RGB {
        let t = t.isNaN ? 0 : min(max(t, 0), 1)
        return RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// Rec. 709 weights on the sRGB values themselves (no linearisation): it
    /// only has to rank colours, light against dark.
    var luminance: Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
