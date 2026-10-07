import AppKit
import SwiftUI

/// What the zoomed stage's scroll view needs beyond a plain SwiftUI
/// `ScrollView`, to scroll the way Device Hub's does (measured on DH 27.0:
/// no scroller at rest at any zoom, a hint over the pill, and ⌥⌘ with a drag
/// moves the picture around):
///
/// - the system's overlay scrollers, which appear while scrolling and fade
///   away, instead of the always-visible legacy bars that a connected mouse
///   turns on and that covered the pill's band;
/// - a drag with ⌥ and ⌘ held pans the stage (the picture follows the
///   pointer); the drag never reaches the device.
///
/// Placed as a background of the scroll view's content; it finds the
/// enclosing `NSScrollView` once the content is in a window.
struct StageScrollSupport: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe {
        Probe()
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.configure()
    }

    static func dismantleNSView(_ nsView: Probe, coordinator: ()) {
        nsView.stop()
    }

    /// The modifiers that turn a drag into a pan.
    static let panModifiers: NSEvent.ModifierFlags = [.option, .command]

    /// Whether a drag with `flags` held pans: ⌥ and ⌘, and nothing else that
    /// changes what a drag means (⌃ is a right click).
    static func isPanGesture(_ flags: NSEvent.ModifierFlags) -> Bool {
        let held = flags.intersection(.deviceIndependentFlagsMask)
        return held.contains(panModifiers) && !held.contains(.control)
    }

    /// The clip origin after a drag by (`dx`, `dy`) screen points: the
    /// picture follows the pointer, so the visible rect moves the other way;
    /// clamped to the document.
    static func pannedOrigin(
        from origin: CGPoint,
        dx: CGFloat,
        dy: CGFloat,
        isFlipped: Bool,
        visible: CGSize,
        document: CGSize
    ) -> CGPoint {
        let x = origin.x - dx
        let y = isFlipped ? origin.y - dy : origin.y + dy
        return CGPoint(
            x: min(max(x, 0), max(document.width - visible.width, 0)),
            y: min(max(y, 0), max(document.height - visible.height, 0))
        )
    }

    final class Probe: NSView {
        private weak var scrollView: NSScrollView?
        private var monitor: Any?
        private var isPanning = false
        private var lastPoint = CGPoint.zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { configure() }
        }

        func configure() {
            guard let found = enclosingScrollView else { return }
            scrollView = found
            found.scrollerStyle = .overlay
            found.autohidesScrollers = true
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
                ) { [weak self] event in
                    self?.handle(event) ?? event
                }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if isPanning { NSCursor.pop() }
            isPanning = false
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let scrollView, event.window === scrollView.window, scrollView.window != nil else { return event }
            switch event.type {
            case .leftMouseDown:
                guard StageScrollSupport.isPanGesture(event.modifierFlags) else { return event }
                let point = scrollView.convert(event.locationInWindow, from: nil)
                guard scrollView.bounds.contains(point) else { return event }
                isPanning = true
                lastPoint = event.locationInWindow
                NSCursor.closedHand.push()
                return nil
            case .leftMouseDragged:
                guard isPanning else { return event }
                // From the pointer's own positions (window coordinates grow
                // upward): synthesized drags carry no deltas.
                let point = event.locationInWindow
                pan(scrollView, dx: point.x - lastPoint.x, dy: lastPoint.y - point.y)
                lastPoint = point
                return nil
            case .leftMouseUp:
                guard isPanning else { return event }
                isPanning = false
                NSCursor.pop()
                return nil
            default:
                return event
            }
        }

        private func pan(_ scrollView: NSScrollView, dx: CGFloat, dy: CGFloat) {
            let clip = scrollView.contentView
            guard let document = scrollView.documentView else { return }
            let origin = StageScrollSupport.pannedOrigin(
                from: clip.bounds.origin,
                dx: dx,
                dy: dy,
                isFlipped: clip.isFlipped,
                visible: clip.bounds.size,
                document: document.frame.size
            )
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            scrollView.flashScrollers()
        }
    }
}
