import SwiftUI
import DeviceHubProKit

/// Turns the native device composition into the stage's pose.
///
/// The caller lays the composition out at `layoutScale`, the fit of the pose
/// the device rests in, and applies this modifier, which:
///
/// * rotates it by the animated pose angle and keeps it fitted to the stage
///   while it turns (`PosePresentationEffect`), with a scale that is exactly
///   1 at rest in every pose, so the AppKit video view is shown at its own
///   size and its Metal drawable, sized from its bounds, 1:1;
/// * keeps the layout out of the rotation animation. The rest pose changes in
///   the update that starts the rotation, so the layout changes once, at the
///   start; animated, it would resize the video view (and reallocate its
///   drawable) on every frame of the 250 ms turn;
/// * turns a frame of the pose-independent `stage` size, so the centre it
///   turns around stays put when the layout changes size.
///
/// What is on screen never depends on the rest pose (`PoseFit.correction`):
/// the layout and the effect's scale change together, so the start of a
/// rotation shows no jump, only a sharper drawable.
struct PosePresentation: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.reportsStageScale) private var reportsStageScale
    @Environment(DeviceWorkspace.self) private var workspace: DeviceWorkspace?

    /// Absolute pose angle in degrees; the animated value.
    let angle: Double
    /// The angle the pose comes to rest at (`StagePoseAnimator.restAngle`).
    let restAngle: Double
    /// The composition's native (unscaled) size.
    let nativeSize: CGSize
    /// The box the rotated composition must stay inside.
    let box: CGSize
    /// The stage area the composition is centred in.
    let stage: CGSize

    /// Points per native unit the composition is laid out at.
    var layoutScale: CGFloat {
        PoseFit.scale(angle: restAngle, nativeSize: nativeSize, box: box)
    }

    /// The size the composition occupies at rest (its rest pose's bounding
    /// box at the layout scale): what the stage places an accessory under.
    var restExtent: CGSize {
        let box = PoseFit.rotatedBoundingBox(nativeSize, angle: restAngle)
        let scale = layoutScale
        return CGSize(width: box.width * scale, height: box.height * scale)
    }

    func body(content: Content) -> some View {
        content
            .transaction(value: restAngle) { $0.animation = nil }
            .frame(width: stage.width, height: stage.height)
            .onChange(of: restExtent, initial: true) { _, extent in
                // The main stage only: the compact window shares the views.
                if reportsStageScale { workspace?.window.deviceExtent = extent }
            }
            .modifier(PosePresentationEffect(
                angle: angle,
                restAngle: restAngle,
                nativeSize: nativeSize,
                box: box,
                pixelScale: displayScale
            ))
    }
}

/// Rotates the native device composition by the stage's absolute pose angle
/// and keeps it fitted to the stage while it turns.
///
/// The composition is built in the device's native orientation (skin artwork,
/// native screen rect, texture uprighted by the renderer), so the pose is one
/// continuous wrapper angle. A pure `rotationEffect` would let the rotated
/// bounding box overflow the stage at intermediate angles (the device is
/// fit-to-stage, unlike Device Hub's fixed scale), so the projection also
/// applies `PoseFit`'s correction for the current angle: exactly 1 at rest
/// (the layout carries the rest pose's fit scale), below 1 toward 45°. In
/// the quarter-turn poses it also moves the composition onto the pixel grid
/// (`PoseFit.pixelGridOffset`), so the 1:1 video is not resampled half a
/// pixel off.
struct PosePresentationEffect: GeometryEffect {
    /// Absolute pose angle in degrees.
    var angle: Double
    /// The angle the pose comes to rest at; the layout carries its fit.
    let restAngle: Double
    /// The composition's native (unscaled) size.
    let nativeSize: CGSize
    /// The box the rotated composition must stay inside.
    let box: CGSize
    /// Backing pixels per point.
    let pixelScale: CGFloat

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let scale = PoseFit.correction(
            angle: angle,
            restAngle: restAngle,
            nativeSize: nativeSize,
            box: box
        )
        // The frame this turns sits on whole pixels (its size and place
        // are the stage's), so the offset only depends on its size.
        let gridOffset = PoseFit.pixelGridOffset(angle: angle, size: size, pixelScale: pixelScale)
        let transform = CGAffineTransform(
            translationX: size.width / 2 + gridOffset,
            y: size.height / 2 + gridOffset
        )
            .rotated(by: angle * .pi / 180)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(transform)
    }
}
