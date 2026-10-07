import CoreGraphics
import Foundation

/// A color in the annotation model: components in the 0...1 range, clamped on
/// the way in so an out-of-range picker value can never corrupt the render.
public struct RGBA: Sendable, Equatable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// CoreGraphics equivalent, for drawing.
    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// One annotation drawn over a screenshot. Coordinates and sizes are in the
/// editor's point space (origin top-left, y down); `AnnotationRenderer` maps
/// them to image pixels through its `scale` argument.
public enum Annotation: Sendable, Equatable, Codable {
    /// A line with a two-stroke head at `to`.
    case arrow(from: CGPoint, to: CGPoint, color: RGBA, width: CGFloat)
    /// A rectangle outline, or a filled block when `filled` is true.
    case rectangle(CGRect, color: RGBA, width: CGFloat, filled: Bool)
    /// A single line of text whose top-left corner sits at `at`.
    case text(String, at: CGPoint, color: RGBA, size: CGFloat)
    /// A redaction over the rect, for hiding sensitive content: an opaque
    /// `AnnotationRenderer.redactionColor` fill, not a reversible blur or
    /// mosaic (the case keeps its name for Codable compatibility).
    case blur(CGRect)
}
