import Foundation

/// Maps a point in the streamed frame to the emulator's touch space.
///
/// The sent frame is shown exactly as the emulator composed it: a buffer in the
/// device's physical pose. The emulator's `sendTouch` expects coordinates in
/// the display's upright orientation (what Android calls the logical display),
/// so the point is rotated by the same amount that would upright the frame —
/// the inverse of the physical rotation the emulator baked into the buffer.
public enum TouchMapping {
    /// Rotates a point inside the displayed frame (`frameWidth` × `frameHeight`,
    /// laid out in the stream's orientation) into the upright touch space for
    /// the given device rotation (0...3, mirrored from `ImageFormat.rotation`).
    public static func nativePoint(
        x: Int,
        y: Int,
        frameWidth: Int,
        frameHeight: Int,
        rotation: Int
    ) -> (x: Int, y: Int) {
        let rotation = ((rotation % 4) + 4) % 4

        let nx: Int
        let ny: Int
        switch rotation {
        case 1:
            nx = frameHeight - 1 - y
            ny = x
        case 2:
            nx = frameWidth - 1 - x
            ny = frameHeight - 1 - y
        case 3:
            nx = y
            ny = frameWidth - 1 - x
        default:
            nx = x
            ny = y
        }

        // Quarter turns transpose the upright space.
        let uprightWidth = rotation % 2 == 1 ? frameHeight : frameWidth
        let uprightHeight = rotation % 2 == 1 ? frameWidth : frameHeight
        return (
            x: max(0, min(uprightWidth - 1, nx)),
            y: max(0, min(uprightHeight - 1, ny))
        )
    }
}
