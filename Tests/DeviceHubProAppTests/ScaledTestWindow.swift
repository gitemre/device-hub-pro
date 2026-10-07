import AppKit

/// An offscreen borderless window for hosted stage tests, at a backing scale
/// the test picks rather than the one of the display the tests happen to run
/// on (they have been run at both 1x and 2x).
///
/// It answers `backingScaleFactor` with the forced scale, and everything the
/// stage derives from the scale follows it: SwiftUI's `displayScale` (so its
/// layout rounds to that pixel grid, a whole point at 1x and a half at 2x),
/// `NSView.convertToBacking`, and the Metal view's drawable and contents
/// scale (`MirrorMetalView.syncDrawableSize`). Checked by
/// `testAForcedScaleReachesTheStage` in `PosedStageTests`.
final class ScaledTestWindow: NSWindow {
    /// The scale answered in place of the screen's; nil answers the
    /// screen's.
    private(set) var forcedScale: CGFloat?

    override var backingScaleFactor: CGFloat {
        forcedScale ?? super.backingScaleFactor
    }

    /// A window of `size` hosting `content`, at `scale` (nil: the screen's).
    /// The scale is set before the content moves in, so SwiftUI lays it out
    /// on that grid from its first pass.
    static func hosting(_ content: NSView, size: CGSize, scale: CGFloat?) -> ScaledTestWindow {
        let window = ScaledTestWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.forcedScale = scale
        window.isReleasedWhenClosed = false
        content.frame = CGRect(origin: .zero, size: size)
        window.contentView = content
        return window
    }
}
