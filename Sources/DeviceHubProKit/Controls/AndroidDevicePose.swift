import Foundation

/// The emulator's device pose: the physical-model rotation Rotate sets, in
/// the stage's count of counter-clockwise quarter turns (left is 1).
///
/// The frame follows this pose, never the display rotation. On a phone
/// Android keeps its previous rotation when the device is held upside down
/// (`config_allowAllRotations` is false), so the home screen stays put and
/// shows upside down to the viewer; on a tablet image that allows all four
/// rotations Android turns to 180 and the picture is upright again. Either
/// way the picture is the guest display turned by the rotation the stream
/// reports (the texture turn), relative to the device frame.
public enum AndroidDevicePose {
    /// The quarter turns (0...3) of a physical-model rotation about the
    /// vertical axis, in degrees (the emulator accumulates every Rotate
    /// press, so it may be negative or past 360). Nearest quarter.
    public static func turns(forRotationDegrees degrees: Float) -> Int {
        guard degrees.isFinite else { return 0 }
        return TextureRotation.normalized(Int((degrees / 90).rounded()))
    }
}
