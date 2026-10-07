import AppKit
import DeviceHubProKit

/// Pointer input a session can deliver as real mouse events rather than
/// touches: scrcpy's wheel and its right click (Back, or power on).
protocol MirrorPointerInput: AnyObject {
    /// Whether wheel events reach the device right now (the control socket
    /// is up). Otherwise scrolling falls back to a synthesized touch drag.
    var acceptsScroll: Bool { get }
    /// Scrolls at a frame point by wheel steps in [-1, 1]: positive
    /// `vertical` scrolls up, positive `horizontal` scrolls right.
    func sendScroll(x: Int32, y: Int32, horizontal: Float, vertical: Float)
    /// BACK, or POWER when the device screen is off.
    func sendBackOrScreenOn()
}

extension PhysicalMirrorSession: MirrorPointerInput {
    var acceptsScroll: Bool { usesControlSocket }
}

/// Shared trackpad/mouse gesture handling for the mirror surfaces.
///
/// - A click-drag is a single touch.
/// - Trackpad pinch (magnify events) and Option+drag synthesize two contacts
///   that move apart/together, which Android turns into pinch zoom.
/// - Scrolling becomes real wheel events on a session that takes them (a
///   physical device over scrcpy's control socket). The emulated guest has no
///   mouse device (wheel RPCs are a no-op there), so elsewhere trackpad and
///   wheel scrolling become a one-finger touch drag that follows the scroll
///   once it has passed Android's touch slop.
/// - A right click is Back on a session that takes it.
@MainActor
final class MirrorInputController {
    /// Runs `work` after `delay` seconds and returns a cancel handle.
    typealias Scheduler = (
        _ delay: TimeInterval,
        _ work: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void

    /// Converts a point in view coordinates to logical mirror coordinates.
    var logicalPoint: ((CGPoint) -> (x: Int32, y: Int32)?)?
    /// Logical frame size, used to scale synthesized pinch distances and to
    /// keep synthesized scroll strokes on the display.
    var frameSize: (() -> CGSize?)?
    /// View points per frame pixel of the image on screen, so a scroll moves
    /// the content by what the fingers moved on screen at any zoom.
    var pointsPerFramePixel: (() -> CGFloat?)?
    /// Frame pixels per dp from the density the device reports, or nil
    /// while it is unknown (then `estimatedPixelsPerDp` stands in).
    var reportedPixelsPerDp: ((CGSize) -> CGFloat?)?
    var sendContacts: (([TouchCommand]) -> Void)?
    /// The session's mouse-event input, when it has one.
    var pointerInput: (() -> (any MirrorPointerInput)?)?
    /// Injectable for tests; the default runs on the main queue.
    var schedule: Scheduler = MirrorInputController.mainQueueScheduler

    private var isDragging = false
    private var lastPoint: (x: Int32, y: Int32)?

    private var isModifierPinch = false
    private var modifierAnchor: (x: Int32, y: Int32)?

    private var magnifyActive = false
    private var magnifyCumulative: CGFloat = 0
    private var magnifyCenter: (x: Int32, y: Int32)?

    /// The synthesized scroll finger: pending while the scroll has not yet
    /// travelled past the touch slop, down after that.
    private var stroke: ScrollStroke?
    private var cancelLift: (@MainActor () -> Void)?

    private struct ScrollStroke {
        /// Where the finger goes, or went, down (frame pixels).
        var anchor: CGPoint
        /// Distance scrolled from the anchor (frame pixels).
        var offset: CGPoint
        /// The last point sent; nil while the finger is not down yet.
        var last: (x: Int32, y: Int32)?
    }

    /// How long the synthesized finger rests before it lifts: past Android's
    /// 40 ms "pointer stopped" window, so the lift itself never flings. The
    /// motion, momentum included, was already delivered as drag moves.
    static let stillBeforeLift: TimeInterval = 0.06
    /// A wheel without phases (a plain mouse): lift once its events stop.
    static let wheelIdleLift: TimeInterval = 0.12
    /// Android scrolls about 64 dp per wheel unit (ViewConfiguration's
    /// scroll factor); one mouse-wheel line is one unit.
    static let dpPerWheelUnit: CGFloat = 64
    /// Until the device reports its density, the frame's short side is
    /// taken as ~411 dp (a typical phone) to estimate it; the system-gesture
    /// insets, the touch slop and the wheel gain depend on it.
    static let assumedShortSideDp: CGFloat = 411
    /// Android's system gesture zones, in dp: a synthesized finger touching
    /// down there would pull the notification shade (top), go Home (bottom
    /// gesture bar) or go Back (sides) instead of scrolling.
    static let gestureInsetsDp = NSEdgeInsets(top: 48, left: 32, bottom: 48, right: 32)
    /// How far a scroll travels, in dp, before its finger goes down: past
    /// Android's touch slop (8 dp) vertically and its paging slop (16 dp,
    /// the launcher's home screen and ViewPager) horizontally, with 2 dp to
    /// spare. The finger then goes down and moves the whole distance at
    /// once, so the scrolling container intercepts on the first move. A
    /// shorter stroke would reach the view under the finger as a tap, and a
    /// finger resting under the slop as a long press.
    static let touchSlopDp = CGSize(width: 18, height: 10)

    static let mainQueueScheduler: Scheduler = { delay, work in
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { work() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    // MARK: - Mouse (single touch, Option+drag pinch)

    func mouseDown(_ event: NSEvent, in view: NSView) {
        endScroll()
        let location = view.convert(event.locationInWindow, from: nil)
        guard let point = logicalPoint?(location) else { return }
        lastPoint = point

        if event.modifierFlags.contains(.option) {
            isModifierPinch = true
            modifierAnchor = point
            sendContacts?([
                TouchCommand(phase: .down, x: point.x, y: point.y, id: 1),
                TouchCommand(phase: .down, x: point.x, y: point.y, id: 2),
            ])
            return
        }

        isDragging = true
        sendContacts?([TouchCommand(phase: .down, x: point.x, y: point.y)])
    }

    func mouseDragged(_ event: NSEvent, in view: NSView) {
        let location = view.convert(event.locationInWindow, from: nil)
        guard let point = logicalPoint?(location) else { return }
        lastPoint = point

        if isModifierPinch, let anchor = modifierAnchor {
            sendContacts?([
                TouchCommand(phase: .move, x: anchor.x, y: anchor.y, id: 1),
                TouchCommand(phase: .move, x: point.x, y: point.y, id: 2),
            ])
            return
        }

        guard isDragging else { return }
        sendContacts?([TouchCommand(phase: .move, x: point.x, y: point.y)])
    }

    func mouseUp(_ event: NSEvent, in view: NSView) {
        let location = view.convert(event.locationInWindow, from: nil)
        let point = logicalPoint?(location) ?? lastPoint

        if isModifierPinch {
            isModifierPinch = false
            modifierAnchor = nil
            if let point {
                sendContacts?([
                    TouchCommand(phase: .up, x: point.x, y: point.y, id: 1),
                    TouchCommand(phase: .up, x: point.x, y: point.y, id: 2),
                ])
            }
            return
        }

        guard isDragging, let point else { return }
        isDragging = false
        sendContacts?([TouchCommand(phase: .up, x: point.x, y: point.y)])
    }

    /// Lifts every synthesized contact now: the scroll finger (and its
    /// pending lift), a mouse drag, an Option-drag or a trackpad pinch. The
    /// view calls it while `sendContacts` still reaches the session those
    /// contacts went down on, before it switches to another session or goes
    /// away; the rest of the gesture is then ignored, or starts afresh.
    func liftAll() {
        endScroll()
        finishMagnify()
        if isModifierPinch {
            isModifierPinch = false
            modifierAnchor = nil
            if let point = lastPoint {
                sendContacts?([
                    TouchCommand(phase: .up, x: point.x, y: point.y, id: 1),
                    TouchCommand(phase: .up, x: point.x, y: point.y, id: 2),
                ])
            }
        }
        if isDragging {
            isDragging = false
            if let point = lastPoint {
                sendContacts?([TouchCommand(phase: .up, x: point.x, y: point.y)])
            }
        }
        lastPoint = nil
    }

    /// A right click: Back on a session that takes it (scrcpy's binding).
    /// Returns false when the session has no such input.
    func secondaryClick() -> Bool {
        guard let pointer = pointerInput?() else { return false }
        pointer.sendBackOrScreenOn()
        return true
    }

    // MARK: - Trackpad pinch

    func magnify(with event: NSEvent, in view: NSView) {
        let location = view.convert(event.locationInWindow, from: nil)

        switch event.phase {
        case .began:
            guard let point = logicalPoint?(location) else { return }
            endScroll()
            magnifyActive = true
            magnifyCumulative = 0
            magnifyCenter = point
            sendContacts?(pinchContacts(at: point, distance: pinchDistance, phase: .down))

        case .ended, .cancelled:
            finishMagnify()

        default:
            guard magnifyActive else {
                // Some devices deliver magnification without a begin phase.
                guard let point = logicalPoint?(location) else { return }
                endScroll()
                magnifyActive = true
                magnifyCumulative = 0
                magnifyCenter = point
                sendContacts?(pinchContacts(at: point, distance: pinchDistance, phase: .down))
                return
            }
            magnifyCumulative += event.magnification
            guard let center = magnifyCenter else { return }
            let factor = max(0.15, min(4.0, 1 + magnifyCumulative))
            sendContacts?(pinchContacts(at: center, distance: pinchDistance * factor, phase: .move))
        }
    }

    private func finishMagnify() {
        guard magnifyActive else { return }
        magnifyActive = false
        if let center = magnifyCenter {
            sendContacts?(pinchContacts(at: center, distance: pinchDistance, phase: .up))
        }
        magnifyCenter = nil
    }

    private var pinchDistance: CGFloat {
        guard let size = frameSize?(), size.width > 1, size.height > 1 else { return 220 }
        return max(80, min(size.width, size.height) * 0.18)
    }

    private func pinchContacts(
        at center: (x: Int32, y: Int32),
        distance: CGFloat,
        phase: TouchCommand.Phase
    ) -> [TouchCommand] {
        let half = Int32(distance / 2)
        return [
            TouchCommand(phase: phase, x: center.x - half, y: center.y, id: 1),
            TouchCommand(phase: phase, x: center.x + half, y: center.y, id: 2),
        ]
    }

    // MARK: - Scroll

    /// One scroll event, decoupled from `NSEvent` so the gesture logic is
    /// testable.
    struct ScrollSample {
        /// In view coordinates.
        var location: CGPoint
        /// Content movement: positive x moves the content right, positive y
        /// moves it down (reveals what is above). Points when precise, lines
        /// otherwise.
        var deltaX: CGFloat
        var deltaY: CGFloat
        var hasPreciseDeltas: Bool
        var phase: NSEvent.Phase
        var momentumPhase: NSEvent.Phase

        init(
            location: CGPoint,
            deltaX: CGFloat,
            deltaY: CGFloat,
            hasPreciseDeltas: Bool = true,
            phase: NSEvent.Phase = [],
            momentumPhase: NSEvent.Phase = []
        ) {
            self.location = location
            self.deltaX = deltaX
            self.deltaY = deltaY
            self.hasPreciseDeltas = hasPreciseDeltas
            self.phase = phase
            self.momentumPhase = momentumPhase
        }

        var moves: Bool {
            (deltaX != 0 || deltaY != 0) && deltaX.isFinite && deltaY.isFinite
        }
    }

    func scrollWheel(with event: NSEvent, in view: NSView) {
        scroll(ScrollSample(
            location: view.convert(event.locationInWindow, from: nil),
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase
        ))
    }

    func scroll(_ sample: ScrollSample) {
        // A mouse drag, Option-pinch or trackpad pinch owns the finger; a
        // scroll stroke would put a second finger down with the same id.
        guard !isDragging, !isModifierPinch, !magnifyActive else { return }

        if let pointer = pointerInput?(), pointer.acceptsScroll {
            endScroll()
            wheel(sample, into: pointer)
            return
        }
        touchScroll(sample)
    }

    /// Real wheel events: one per sample, split into [-1, 1] steps.
    /// Resting fingers (`.mayBegin`) and zero deltas send nothing.
    private func wheel(_ sample: ScrollSample, into pointer: any MirrorPointerInput) {
        guard sample.moves,
              let point = logicalPoint?(sample.location),
              let frame = frameSize?()
        else {
            return
        }
        let units: (horizontal: CGFloat, vertical: CGFloat)
        if sample.hasPreciseDeltas {
            let pixelsPerUnit = Self.wheelUnitPixels(pixelsPerDp: pixelsPerDp(frame: frame))
            let pointsPerPixel = max(pointsPerFramePixel?() ?? 1, 0.01)
            units = (
                -sample.deltaX / pointsPerPixel / pixelsPerUnit,
                sample.deltaY / pointsPerPixel / pixelsPerUnit
            )
        } else {
            units = (-sample.deltaX, sample.deltaY)
        }
        var horizontal = units.horizontal
        var vertical = units.vertical
        // A fast mouse wheel reports several lines per event; bound the
        // burst so a pathological delta cannot flood the socket.
        for _ in 0..<16 {
            let stepX = max(-1, min(1, horizontal))
            let stepY = max(-1, min(1, vertical))
            pointer.sendScroll(x: point.x, y: point.y, horizontal: Float(stepX), vertical: Float(stepY))
            horizontal -= stepX
            vertical -= stepY
            if abs(horizontal) < 1e-3, abs(vertical) < 1e-3 { break }
        }
    }

    /// The emulated scroll: a finger that goes down where the pointer is
    /// (moved clear of the system-gesture zones) once the scroll has passed
    /// the touch slop, and follows the scroll deltas. One stroke spans a
    /// whole trackpad gesture including its momentum; it lifts only once
    /// still, so it never flings on its own.
    private func touchScroll(_ sample: ScrollSample) {
        if sample.moves {
            drag(by: sample)
        }
        guard stroke != nil else {
            // Resting fingers (`.mayBegin`), a cancel without movement and
            // zero deltas never touch the device.
            return
        }
        if sample.momentumPhase == .began || sample.momentumPhase == .changed {
            // Momentum took over from `.ended`: the finger stays down even
            // while an event carries no delta.
            cancelPendingLift()
        } else if sample.momentumPhase == .ended || sample.momentumPhase == .cancelled
            || sample.phase == .ended || sample.phase == .cancelled
            || sample.phase == .mayBegin
        {
            // Momentum may still follow `.ended` (it cancels this lift); a
            // `.mayBegin` during momentum is the fingers stopping it.
            scheduleLift(after: Self.stillBeforeLift)
        } else if sample.phase.isEmpty, sample.momentumPhase.isEmpty {
            // A plain mouse wheel has no phases: lift once it stops.
            scheduleLift(after: Self.wheelIdleLift)
        }
    }

    private func drag(by sample: ScrollSample) {
        guard let frame = frameSize?(), frame.width >= 1, frame.height >= 1 else { return }
        let density = pixelsPerDp(frame: frame)
        let delta: CGPoint
        if sample.hasPreciseDeltas {
            let pointsPerPixel = max(pointsPerFramePixel?() ?? 1, 0.01)
            delta = CGPoint(x: sample.deltaX / pointsPerPixel, y: sample.deltaY / pointsPerPixel)
        } else {
            let pixels = Self.wheelUnitPixels(pixelsPerDp: density)
            delta = CGPoint(x: sample.deltaX * pixels, y: sample.deltaY * pixels)
        }

        cancelPendingLift()
        if stroke == nil {
            guard let point = logicalPoint?(sample.location) else { return }
            let anchor = Self.touchDownPoint(
                near: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)),
                frame: frame,
                pixelsPerDp: density
            )
            stroke = ScrollStroke(anchor: anchor, offset: .zero)
        }
        guard var current = stroke else { return }

        let display = CGRect(x: 0, y: 0, width: frame.width - 1, height: frame.height - 1)
        let slop = Self.touchSlopPixels(pixelsPerDp: density)
        current.offset.x += delta.x
        current.offset.y += delta.y
        // Under the slop no finger is down yet: nothing reaches the device
        // until the stroke would scroll, and a gesture that ends here (the
        // pending lift) sends nothing at all.
        guard current.last != nil || Self.passes(current.offset, slop: slop) else {
            stroke = current
            return
        }
        if current.last == nil {
            current.last = putDown(at: current.anchor)
        }

        var target = CGPoint(x: current.anchor.x + current.offset.x, y: current.anchor.y + current.offset.y)
        if !display.contains(target) {
            // The finger reached the display edge, where it would pin and
            // the scroll would stall: lift it there and put it down again at
            // the anchor with the remaining distance, once that passes the
            // slop too.
            let edge = Self.clamped(target, to: display)
            let lifted = Self.rounded(edge)
            sendContacts?([TouchCommand(phase: .move, x: lifted.x, y: lifted.y)])
            sendContacts?([TouchCommand(phase: .up, x: lifted.x, y: lifted.y)])
            target = Self.clamped(
                CGPoint(x: current.anchor.x + target.x - edge.x, y: current.anchor.y + target.y - edge.y),
                to: display
            )
            current.offset = CGPoint(x: target.x - current.anchor.x, y: target.y - current.anchor.y)
            current.last = nil
            guard Self.passes(current.offset, slop: slop) else {
                stroke = current
                return
            }
            current.last = putDown(at: current.anchor)
        }
        let moved = Self.rounded(target)
        current.last = moved
        stroke = current
        sendContacts?([TouchCommand(phase: .move, x: moved.x, y: moved.y)])
    }

    /// Sends the scroll finger's touch-down and returns where it went down.
    private func putDown(at anchor: CGPoint) -> (x: Int32, y: Int32) {
        let down = Self.rounded(anchor)
        sendContacts?([TouchCommand(phase: .down, x: down.x, y: down.y)])
        return down
    }

    private func scheduleLift(after delay: TimeInterval) {
        cancelPendingLift()
        cancelLift = schedule(delay) { [weak self] in
            self?.cancelLift = nil
            self?.endScroll()
        }
    }

    private func cancelPendingLift() {
        cancelLift?()
        cancelLift = nil
    }

    /// Lifts the scroll finger now, if it is down, and drops a stroke that
    /// never passed the slop.
    private func endScroll() {
        cancelPendingLift()
        guard let current = stroke else { return }
        stroke = nil
        guard let last = current.last else { return }
        sendContacts?([TouchCommand(phase: .up, x: last.x, y: last.y)])
    }

    // MARK: - Scroll geometry

    /// Frame pixels per dp: the device's reported density when known,
    /// else estimated from the frame's short side.
    func pixelsPerDp(frame: CGSize) -> CGFloat {
        if let reported = reportedPixelsPerDp?(frame), reported.isFinite, reported > 0 {
            return max(reported, 0.1)
        }
        return Self.estimatedPixelsPerDp(frame: frame)
    }

    /// Frame pixels per dp for a frame whose short side is ~411 dp.
    static func estimatedPixelsPerDp(frame: CGSize) -> CGFloat {
        max(min(frame.width, frame.height) / assumedShortSideDp, 0.1)
    }

    /// Frame pixels one wheel unit scrolls.
    static func wheelUnitPixels(pixelsPerDp density: CGFloat) -> CGFloat {
        dpPerWheelUnit * density
    }

    /// `touchSlopDp` in frame pixels.
    static func touchSlopPixels(pixelsPerDp density: CGFloat) -> CGSize {
        CGSize(width: touchSlopDp.width * density, height: touchSlopDp.height * density)
    }

    /// Whether a scroll distance is past the slop on either axis.
    private static func passes(_ offset: CGPoint, slop: CGSize) -> Bool {
        abs(offset.x) > slop.width || abs(offset.y) > slop.height
    }

    /// Where a synthesized scroll finger touches down for a pointer at
    /// `point`: the point itself, moved out of the system-gesture zones.
    static func touchDownPoint(near point: CGPoint, frame: CGSize, pixelsPerDp density: CGFloat) -> CGPoint {
        let insets = gestureInsetsDp
        let safe = CGRect(
            x: insets.left * density,
            y: insets.top * density,
            width: frame.width - 1 - (insets.left + insets.right) * density,
            height: frame.height - 1 - (insets.top + insets.bottom) * density
        )
        guard safe.width > 0, safe.height > 0 else {
            return CGPoint(x: (frame.width - 1) / 2, y: (frame.height - 1) / 2)
        }
        return clamped(point, to: safe)
    }

    private static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private static func rounded(_ point: CGPoint) -> (x: Int32, y: Int32) {
        (Int32(point.x.rounded()), Int32(point.y.rounded()))
    }
}
