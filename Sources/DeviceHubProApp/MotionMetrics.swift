import AppKit
import SwiftUI

/// Motion design tokens for the app's interaction animations.
///
/// Every token is either measured against Device Hub with
/// `Scripts/motion-probe.sh` (recorded window video → frame timing, see the
/// `MOTION-xx` rows in the parity audit) or HIG-designed where DH has no
/// measurable counterpart. Views must not hardcode durations or curves —
/// this file is the single source, exactly like `ParityMetrics` for geometry.
enum MotionMetrics {
    // MARK: - Measured (Device Hub)

    /// Device rotation: MOTION-01. DH rotates the whole device (frame and
    /// screen together) in ~250 ms, starting fast and stopping quickly.
    static let heroDuration: TimeInterval = 0.25
    static let hero = Animation.easeOut(duration: heroDuration)

    /// Zoom steps: MOTION-02. DH animates the device scale over ~283 ms with
    /// an ease-in-out profile.
    static let zoomDuration: TimeInterval = 0.28
    static let zoom = Animation.easeInOut(duration: zoomDuration)

    // MARK: - HIG-designed

    /// Selection changes (sidebar pill, segmented pill). MOTION-04/05
    /// measured DH swapping these instantly; the short fade is a deliberate,
    /// documented deviation for polish.
    static let selectionDuration: TimeInterval = 0.12
    static let selection = Animation.easeOut(duration: selectionDuration)

    /// Stage and inspector transitions that DH itself performs instantly
    /// (MOTION-04 device switch, MOTION-05 inspector tab). Kept short so the
    /// deviation reads as polish, not as a different interaction model.
    static let standardDuration: TimeInterval = 0.25
    static let standard = Animation.easeInOut(duration: standardDuration)

    /// Status banner and success flashes. No DH counterpart.
    static let bannerDuration: TimeInterval = 0.2
    static let banner = Animation.easeOut(duration: bannerDuration)

    // MARK: - Fold stage (HIG-designed, reference video)

    /// Fold/unfold ramp: the reference simulator folds in ~0.5 s (spec §3).
    /// Parity row: MOTION-07.
    static let foldDuration: TimeInterval = 0.5
    /// Hinge command cadence of `runPostureAnimation` — I/O pacing, not motion.
    static let foldStepInterval: TimeInterval = 0.016

    // MARK: - Device frame buttons (HIG-designed, provisional: MOTION-08)

    /// The side buttons painted into a Pixel skin's frame
    /// (`HardwareButtonsLayer`, HW-01) roll out under the pointer like a
    /// physical button: the sprite slides out of the body on hover, eases
    /// back a moment after the pointer leaves, and sinks into the body while
    /// held. Provisional until Device Hub's own rollover is measured with
    /// `Scripts/motion-probe.sh` (MOTION-08).
    ///
    /// Device Hub's pointer tokens (`PointerFeedback`) are its toolbar
    /// platters and are not used here: those change within one frame and
    /// draw a fill behind the control, where a device's button is part of
    /// the body and moves. What is shared is the press's darkening: DH's
    /// held platter is ≈8 % darker than its rest (`secondarySystemFill`,
    /// 7.8 %), and a held button is multiplied by `chromePressTint` (8 %
    /// darker), applied at once as DH's is; only its travel animates.
    static let chromeHoverOnDuration: TimeInterval = 0.15
    static let chromeHoverOn = Animation.easeOut(duration: chromeHoverOnDuration)
    /// How long a popped button waits after the pointer left before it
    /// eases back, so crossing the gap between two buttons does not flicker.
    static let chromeHoverOffDelay: TimeInterval = 0.10
    static let chromeHoverOffDuration: TimeInterval = 0.20
    static let chromeHoverOff = Animation.easeInOut(duration: chromeHoverOffDuration)
    /// A press's travel into the body and back: as short as a selection
    /// change (`selectionDuration`), so a click reads as one.
    static let chromePressDuration: TimeInterval = 0.12
    static let chromePress = Animation.easeOut(duration: chromePressDuration)
    /// Once every button is back at rest, the frame split into sprites
    /// hands back to the artwork drawn whole by cross-fading over this long
    /// (`HardwareButtonsState.restFade`): the two differ by up to 88 levels
    /// around the buttons on a 1x display, so a switch in one frame would
    /// show as a jump with nothing moving. As long as the ease back, so the
    /// fade reads as its tail.
    static let chromeRestFadeDuration: TimeInterval = 0.20
    static let chromeRestFade = Animation.easeInOut(duration: chromeRestFadeDuration)

    /// Hover travel in artwork pixels per pixel of the button's depth: a
    /// 10 px deep Pixel 10 Pro button rolls out 14 px, ≈4 pt at its stage
    /// fit (0.283 pt per pixel).
    static let chromeHoverTravelPerDepth: CGFloat = 1.4
    /// The hover travel's bounds in artwork pixels, so the 4 px buttons of
    /// the open 9 Pro Fold still visibly move and a deep one does not leap.
    static let chromeHoverTravelPixels: ClosedRange<CGFloat> = 8...16
    /// The hover travel's bound on screen, points: it has to stay inside the
    /// stage's button pad (at most 8 pt).
    static let chromeHoverTravelMaxPoints: CGFloat = 6
    /// A held button sinks this share of its depth into the body.
    static let chromePressDepthShare: CGFloat = 0.6
    /// A held button's colour multiplier (8 % darker, DH's pressed step).
    static let chromePressTint: Double = 0.92

    // MARK: - Reduce Motion

    /// Model-side Reduce Motion gate: `AppModel` and other non-view code cannot
    /// read the SwiftUI environment, so they use the system setting directly
    /// (the same check `runPostureAnimation` has always used).
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Runs `body` in an animation unless Reduce Motion is on.
    static func run(_ animation: Animation, reduceMotion: Bool, _ body: () -> Void) {
        if reduceMotion {
            body()
        } else {
            withAnimation(animation, body)
        }
    }

    /// Model-side convenience: `run` gated on the system setting.
    static func run(_ animation: Animation, _ body: () -> Void) {
        run(animation, reduceMotion: reduceMotion, body)
    }

    /// How far a frame button `depth` artwork pixels deep rolls out on
    /// hover, in artwork pixels, at `pointsPerPixel` points per artwork
    /// pixel: `round(1.4 × depth)`, held to 8–16 px and to 6 pt on screen.
    /// None under Reduce Motion.
    static func chromeHoverTravel(depth: Int, pointsPerPixel: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, depth > 0 else { return 0 }
        let pixels = min(
            max((chromeHoverTravelPerDepth * CGFloat(depth)).rounded(), chromeHoverTravelPixels.lowerBound),
            chromeHoverTravelPixels.upperBound
        )
        guard pointsPerPixel > 0 else { return pixels }
        return min(pixels, chromeHoverTravelMaxPoints / pointsPerPixel)
    }

    /// How far a held frame button sinks into the body, in artwork pixels
    /// (negative: inward): `−round(0.6 × depth)`. None under Reduce Motion,
    /// where the press shows as the tint only.
    static func chromePressTravel(depth: Int, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, depth > 0 else { return 0 }
        return -(chromePressDepthShare * CGFloat(depth)).rounded()
    }
}

extension View {
    /// Animation scoped to `value`, disabled by Reduce Motion.
    func motion(
        _ animation: Animation,
        value: some Equatable,
        reduceMotion: Bool
    ) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}
