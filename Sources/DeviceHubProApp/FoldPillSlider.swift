import AppKit
import DeviceHubProKit
import Observation
import SwiftUI

/// Whether Option is held, app-wide: Device Hub 27.1 turns a foldable
/// simulator's Rotate into Rotate Left while it is (and swaps the posture
/// glyphs for a hinge slider, which ours keeps in view all the time,
/// `FoldPillLayout`). Flags come from a local monitor of key and pointer
/// events (while the app is active), and leaving the app clears the state,
/// because the key-up goes elsewhere.
@MainActor
@Observable
final class OptionKeyMonitor {
    private(set) var isHeld = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Option is down: its bit is set, whatever else is held.
    static func isOptionHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.option)
    }

    func start() {
        guard monitor == nil else { return }
        isHeld = NSApp?.isActive == true && Self.isOptionHeld(NSEvent.modifierFlags)
        // Pointer events carry the keys held too: a key-up the app missed
        // (released while a menu tracked the mouse) is put right as soon as
        // the pointer moves.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseMoved, .leftMouseDown]) { [weak self] event in
            let held = Self.isOptionHeld(event.modifierFlags)
            MainActor.assumeIsolated { self?.isHeld = held }
            return event
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isHeld = false }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isHeld = Self.isOptionHeld(NSEvent.modifierFlags) }
            },
        ]
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        isHeld = false
    }
}

/// What the fold pill does with Option and the hinge slider.
enum FoldPillSlider {
    /// The slider's width: Device Hub's three posture buttons less its inset
    /// on each side, so it moves the hinge as far per point as Device Hub's
    /// (180° over its 84 pt).
    static let width: CGFloat =
        ParityMetrics.pillButtonWidth * CGFloat(PostureKind.allCases.count) - ParityMetrics.foldPillSliderInset * 2

    /// Which way a tap on a foldable's Rotate turns: right (clockwise, the
    /// device's top goes to the right) as in Device Hub, left while Option
    /// is held (its glyph is `rotate.device.left` then).
    static func rotatesLeft(optionHeld: Bool) -> Bool { optionHeld }
}

/// Lets a drag send the hinge only when its whole-degree value changes: the
/// simulator takes whole degrees (`SimulatorFold.sentAngle`), so the 100+
/// pointer events a second between two degrees would be repeats.
struct HingeCoalescer {
    private(set) var lastSent: Double?

    /// The angle to send for a drag value, or nil when it repeats the last.
    mutating func next(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        let angle = SimulatorFold.sentAngle(degrees)
        guard angle != lastSent else { return nil }
        lastSent = angle
        return angle
    }

    /// A new drag starts from whatever the hinge is at.
    mutating func reset() { lastSent = nil }
}

/// The hinge slider of a foldable simulator's pill: the native macOS slider
/// (as Device Hub draws it), closed (0°) at the left and open (180°) at the
/// right.
struct FoldHingeSlider: View {
    /// The hinge angle to show when no drag is running.
    let angle: Double
    let onChange: (Double) -> Void
    let onDragging: (Bool) -> Void

    @State private var dragAngle: Double?
    @State private var editing = false
    @State private var coalescer = HingeCoalescer()

    private var shownAngle: Double { dragAngle ?? angle }

    var body: some View {
        Slider(
            value: Binding(
                get: { shownAngle },
                set: { degrees in
                    // A drag hands on every angle as it is, which the model
                    // follows (`SimulatorFoldController.dragHinge` sends the
                    // simulator whole degrees); outside one (the keyboard,
                    // VoiceOver) the hinge moves a whole degree at a time and
                    // the slider goes on showing the real angle.
                    if editing {
                        dragAngle = degrees
                        onChange(degrees)
                    } else {
                        coalescer.reset()
                        if let send = coalescer.next(degrees) { onChange(send) }
                    }
                }
            ),
            in: 0...180,
            onEditingChanged: { isEditing in
                editing = isEditing
                if isEditing {
                    coalescer.reset()
                } else {
                    dragAngle = nil
                }
                onDragging(isEditing)
            }
        )
        // Taken away mid-drag (another device selected), the drag is over.
        .onDisappear {
            if editing { onDragging(false) }
            editing = false
            dragAngle = nil
        }
        .controlSize(.regular)
        .labelsHidden()
        .frame(height: ParityMetrics.pillHeight)
        .accessibilityIdentifier("deviceChrome.poseHingeSlider")
        .accessibilityLabel("Hinge angle")
        .accessibilityValue("\(Int(SimulatorFold.sentAngle(shownAngle))) degrees")
    }
}
